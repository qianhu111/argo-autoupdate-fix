#!/bin/sh
# ============================================================
# Argo 自更新保活补丁 (方案 B / fscarmen sing-box / Alpine openrc)
#
# 思路: 不禁用 cloudflared 自动更新，而是按 Cloudflare 官方
#       openrc 服务模板，用 supervise-daemon 托管进程。
#       cloudflared 更新完会 exit 11，supervisor 5 秒内自动
#       拉起加载新版；进程意外崩溃同样能自动复活。
#
# 作用: 1) 去掉 --no-autoupdate（恢复自动更新）
#       2) 把 command_background="yes" 换成
#          supervisor="supervise-daemon" + respawn_delay/max
#       3) 清残留进程与僵死状态，重启并验收（含隧道注册检查）
#
# 幂等: 重复运行结果一致，不会叠加 supervisor 行。
# 对称: 从 A 方案（干净 A 态）切过来也是一步到位。
#
# 用法: sh argo-supervise.sh   （需 root，重启时隧道短暂断连）
# 回滚: 用脚本自动按时间戳备份的 /etc/init.d/argo.bak.b.XXXX
# ============================================================

set -e

SVC="/etc/init.d/argo"
LOG="/etc/sing-box/logs/argo.log"

echo "==> 检查环境"
[ "$(id -u)" = "0" ] || { echo "[X] 需要 root 运行"; exit 1; }
[ -s "$SVC" ] || { echo "[X] 找不到 $SVC，你确定装了 Argo?"; exit 1; }
command -v rc-service >/dev/null 2>&1 || { echo "[X] 不是 openrc 系统，此脚本不适用"; exit 1; }
command -v supervise-daemon >/dev/null 2>&1 || { echo "[X] 找不到 supervise-daemon，openrc 版本太旧?"; exit 1; }
echo "[OK] Alpine/openrc + supervise-daemon 就绪"

echo ""
echo "==> 备份"
BAK="${SVC}.bak.b.$(date +%Y%m%d%H%M%S)"
cp "$SVC" "$BAK"
echo "[OK] 备份到 $BAK"

echo ""
echo "==> 改写服务文件（归一到干净 B 态）"
TMP="${SVC}.tmp.$$"
awk '
/^command_background=/ { next }
/^supervisor=/         { next }
/^respawn_delay=/      { next }
/^respawn_max=/        { next }
{
    print
    if ($0 ~ /^command_args=/) {
        print "supervisor=\"supervise-daemon\""
        print "respawn_delay=5"
        print "respawn_max=0"
    }
}
' "$SVC" > "$TMP"
mv "$TMP" "$SVC"
chmod +x "$SVC"
# 去掉 --no-autoupdate，恢复 cloudflared 自动更新
sed -i 's@ --no-autoupdate@@g' "$SVC"
echo "[OK] 目标状态："
grep -E '^(command_args|supervisor|respawn|command_background)' "$SVC"

echo ""
echo "==> 清理残留进程和僵死状态"
pkill -9 -f '/etc/sing-box/cloudflared' 2>/dev/null || true
sleep 1
rc-service argo zap 2>/dev/null || true
rm -f /var/run/argo.pid
echo "[OK] 清理完成"

# 启动前记录日志行数，验收只看本次新增，避开 UTC 日期比对坑
if [ -s "$LOG" ]; then LOG_BEFORE=$(wc -l < "$LOG"); else LOG_BEFORE=0; fi

echo ""
echo "==> 启动 argo"
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
echo "--- 进程 ---"
ps aux | grep '[c]loudflared' || echo "(无进程)"
if [ "$REGISTERED" = "yes" ]; then
    echo "[OK] 本次启动已见 Registered tunnel connection，隧道注册成功"
else
    echo "[!] 进程在但新日志未见隧道注册——检查 token / 网络 / 稍后手动确认"
fi
echo "--- 日志尾部 ---"
[ -s "$LOG" ] && tail -8 "$LOG" || echo "(日志为空)"
echo ""
echo "==> 完成。以后 cloudflared 更新退出后，openrc 会在 5 秒内自动拉起。"
echo "    回滚: cp $BAK $SVC && rc-service argo restart"
