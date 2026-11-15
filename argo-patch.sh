#!/bin/sh
# ============================================================
# Argo 自更新补丁 (fscarmen sing-box 固定隧道 / Alpine openrc)
#
# 病根: fscarmen 脚本给固定隧道 (config/token) 生成的服务
#       漏了 --no-autoupdate, cloudflared 作为服务跑时会自动
#       更新把自己替换掉然后 exit 11, openrc 不 respawn -> 隧道停。
#
# 作用: 1) 幂等补上 --no-autoupdate (已有则跳过)
#       2) 清残留进程 + openrc 僵死状态
#       3) 重启 argo 并验收
#
# 用法: sh argo-patch.sh
# 注意: 重启期间隧道会短暂断连几秒; 需要 root。
# ============================================================

set -e

SVC="/etc/init.d/argo"
LOG="/etc/sing-box/logs/argo.log"
FLAG="--no-autoupdate"

echo "==> 检查环境"
[ "$(id -u)" = "0" ] || { echo "[X] 需要 root 运行"; exit 1; }
[ -s "$SVC" ] || { echo "[X] 找不到 $SVC，你确定装了 Argo?"; exit 1; }
command -v rc-service >/dev/null 2>&1 || { echo "[X] 不是 openrc 系统，此脚本不适用"; exit 1; }
echo "[OK] Alpine/openrc，服务文件在 $SVC"

echo ""
echo "==> 检查补丁状态"
if grep -q -- "$FLAG" "$SVC"; then
    echo "[=] 补丁已存在，跳过修改（可当一键重启用）"
else
    BAK="${SVC}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$SVC" "$BAK"
    echo "[OK] 已备份到 $BAK"
    sed -i "s@--edge-ip-version auto --protocol http2@--edge-ip-version auto --protocol http2 $FLAG@" "$SVC"
    grep -q -- "$FLAG" "$SVC" || { echo "[X] 补丁写入失败，请手动检查 $SVC"; exit 1; }
    echo "[OK] 补丁已写入"
fi
grep '^command_args=' "$SVC"

echo ""
echo "==> 清理残留进程和僵死状态"
pkill -9 -f '/etc/sing-box/cloudflared' 2>/dev/null || true
sleep 1
rc-service argo zap 2>/dev/null || true
rm -f /var/run/argo.pid
echo "[OK] 清理完成"

echo ""
echo "==> 启动 argo"
rc-service argo start
sleep 3

echo ""
echo "==> 验收"
rc-service argo status
if ps aux | grep -q '[c]loudflared.*--no-autoupdate'; then
    echo "[OK] 进程带 --no-autoupdate 运行中"
else
    echo "[!] 没找到带 --no-autoupdate 的进程，请检查日志"
fi
echo "--- 日志尾部 ---"
[ -s "$LOG" ] && tail -8 "$LOG" || echo "(日志为空)"
echo ""
echo "==> 完成。过几小时瞄一眼日志，只要不冒 'has been updated' 就稳了。"
