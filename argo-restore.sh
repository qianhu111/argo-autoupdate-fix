#!/bin/sh
# ============================================================
# Argo 备份还原脚本 (配套 argo-patch.sh / argo-supervise.sh)
#
# 自动扫描 /etc/init.d/argo.bak*，列出并标注每个备份的状态：
#   A 态 / B 态 / 原始态 / 混合态
# 选中后还原到 /etc/init.d/argo，重启并验收。
#
# 用法:
#   sh argo-restore.sh          # 列出备份，交互选编号
#   sh argo-restore.sh 2        # 直接还原第 2 个（非交互）
#
# 安全: 还原前会自动把当前状态另存一份 .bak.pre-restore.XXXX，
#       所以选错了也能再退回来。
# ============================================================

set -e

SVC="/etc/init.d/argo"
PREFIX="/etc/init.d/argo.bak"
LOG="/etc/sing-box/logs/argo.log"

echo "==> 检查环境"
[ "$(id -u)" = "0" ] || { echo "[X] 需要 root 运行"; exit 1; }
command -v rc-service >/dev/null 2>&1 || { echo "[X] 不是 openrc 系统"; exit 1; }

# 收集备份（排除 pre-restore 自身），按名字排序
BACKUPS=$(ls -1 ${PREFIX}* 2>/dev/null | grep -v 'pre-restore' | sort || true)
[ -n "$BACKUPS" ] || { echo "[X] 没找到任何备份文件"; exit 1; }

# 给每个备份打状态标签
label() {
    f="$1"
    na=$(grep -c -- '--no-autoupdate' "$f" 2>/dev/null || true)
    sp=$(grep -c '^supervisor=' "$f" 2>/dev/null || true)
    if [ "$na" -gt 0 ] && [ "$sp" -eq 0 ]; then
        echo "A 态（禁用自动更新）"
    elif [ "$sp" -gt 0 ] && [ "$na" -eq 0 ]; then
        echo "B 态（supervisor 保活 + 自动更新）"
    elif [ "$sp" -gt 0 ] && [ "$na" -gt 0 ]; then
        echo "混合态（A+B）"
    else
        echo "原始态（无补丁）"
    fi
}

echo ""
echo "==> 找到的备份："
i=0
printf '%s\n' "$BACKUPS" | while read -r b; do
    i=$((i + 1))
    printf '  [%s] %s  ->  %s\n' "$i" "$(basename "$b")" "$(label "$b")"
done

TOTAL=$(printf '%s\n' "$BACKUPS" | wc -l)

if [ -n "$1" ]; then
    choice="$1"
else
    printf "\n输入要还原的编号 (1-%s): " "$TOTAL"
    read -r choice </dev/tty
fi

case "$choice" in
    ''|*[!0-9]*) echo "[X] 编号不合法"; exit 1 ;;
esac
[ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le "$TOTAL" ] 2>/dev/null || { echo "[X] 编号超出范围"; exit 1; }

TARGET=$(printf '%s\n' "$BACKUPS" | sed -n "${choice}p")
echo ""
echo "[i] 选定: $(basename "$TARGET")  ->  $(label "$TARGET")"

echo ""
echo "==> 还原中"
CUR_BAK="${SVC}.bak.pre-restore.$(date +%Y%m%d%H%M%S)"
cp "$SVC" "$CUR_BAK"
echo "[OK] 当前状态已另存: $(basename "$CUR_BAK")"
cp "$TARGET" "$SVC"
chmod +x "$SVC"
pkill -9 -f '/etc/sing-box/cloudflared' 2>/dev/null || true
sleep 1
rc-service argo zap 2>/dev/null || true
rm -f /var/run/argo.pid
# 启动前记录日志行数，验收只看本次新增，避开 UTC 日期比对坑
if [ -s "$LOG" ]; then LOG_BEFORE=$(wc -l < "$LOG"); else LOG_BEFORE=0; fi
rc-service argo start

echo ""
echo "==> 验收（轮询日志最多 20 秒，确认隧道真注册）"
rc-service argo status
REGISTERED=no
i=0
while [ "$i" -lt 10 ]; do
    if [ -s "$LOG" ] && tail -n +$((LOG_BEFORE + 1)) "$LOG" 2>/dev/null | grep -q 'Registered tunnel connection'; then
        REGISTERED=yes
        break
    fi
    i=$((i + 1))
    sleep 2
done
echo "--- 服务文件关键行 ---"
grep -E '^(command_args|supervisor|respawn|command_background)' "$SVC" || true
echo "--- 进程 ---"
ps aux | grep '[c]loudflared' || echo "(无进程)"
if [ "$REGISTERED" = "yes" ]; then
    echo "[OK] 本次启动已见 Registered tunnel connection，隧道注册成功"
else
    echo "[!] 进程在但新日志未见隧道注册——检查 token / 网络 / 稍后手动确认"
fi
echo "--- 日志尾部 ---"
[ -s "$LOG" ] && tail -6 "$LOG" || echo "(日志为空)"
echo ""
echo "==> 完成。反悔就用: cp $CUR_BAK $SVC && rc-service argo restart"
