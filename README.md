# argo-autoupdate-fix

修复 fscarmen sing-box 脚本部署的 Argo 隧道在 Alpine/openrc 环境下「过一段时间自动关闭、且开启失败」的问题。

## 问题现象

用 `bash <(wget -qO- https://raw.githubusercontent.com/fscarmen/sing-box/main/sing-box.sh)` 部署 reality + hysteria2 + vless Argo 节点，其中固定隧道一开始正常，运行一段时间后 Argo 自动关闭，手动开启失败。

## 根本原因

三个因素叠加：

1. **cloudflared 自动更新**：独立二进制作为服务运行时，内置 autoupdate 默认开启，每隔几小时检查新版本，一旦有更新就下载替换自身并以退出码 11 主动退出，依赖 init 系统重新拉起。
2. **openrc 不自动拉起**：Alpine 的 openrc 服务（`/etc/init.d/argo`）没有 respawn 机制，cloudflared 退出后不会自动重启，隧道就此停摆。
3. **fscarmen 脚本的疏漏**：脚本给固定隧道（config / token 模式）生成的服务命令**没有带 `--no-autoupdate`**（只有临时隧道 `--url` 模式带），所以固定隧道用户必然中招。

日志特征（`/etc/sing-box/logs/argo.log`）：

```
cloudflared has been updated version=2026.11.0
Initiating shutdown error="cloudflared has been updated to version 2026.11.0"
Tunnel server stopped
```

> 注：内存紧张不是本次停机的主因。排查时 `oom_kill` 为 0，没有进程被 OOM 杀掉。

## 解决方法

给固定隧道服务补上 `--no-autoupdate`，让 cloudflared 不再自我更新退出。

## 用法

需要 root 权限：

### argo-patch.sh

```bash
wget -qO- https://raw.githubusercontent.com/qianhu111/argo-autoupdate-fix/main/argo-patch.sh | sh
```

脚本做的事：

- 检查环境（root / openrc / 服务文件），不符合直接退出，不乱改
- 幂等补上 --no-autoupdate；已存在则跳过，重复运行安全
- 修改前按时间戳备份 /etc/init.d/argo
- 清理残留进程 + openrc 僵死状态（zap + 删除 pidfile）
- 重启 argo 并验收：检查服务状态、进程参数、日志尾部

### argo-supervise.sh

```bash
wget -qO- https://raw.githubusercontent.com/qianhu111/argo-autoupdate-fix/main/argo-supervise.sh | sh
```

它做的事:

- 查环境:root / openrc / supervise-daemon 存在,缺一样就退,不乱改
- 备份:按时间戳存 argo.bak.b.XXXX(注意后缀 .b,跟 argo-patch.sh 脚本的 .bak.XXXX 区分开)
- 改写:去掉 --no-autoupdate 恢复自动更新;把 command_background="yes" 换成官方三件套 supervisor + respawn_delay=5 + respawn_max=0
- 幂等:重复跑结果一样,不会叠加 supervisor 行——我刚拿模拟服务文件实测过改写逻辑,输出正确
- 清僵死 + 重启 + 验收:跟 argo-patch.sh 脚本一套流程

### 两个脚本的区别:
| |argo-patch.sh (A)|argo-supervise.sh (B)|
|---|---|---|
|自动更新|禁用|保留|
|靠什么续命|不退出,一劳永逸|退出后 supervisor 5 秒拉起|
|附带好处|版本冻结|崩溃也能自动复活|

### 互转:
这俩互为逆操作。A→B 直接跑 B;B→A 直接跑 A(会加回 --no-autoupdate,但 A 脚本不会删 supervisor——所以从 B 回 A 的话,跑完 A 记得手动把那三行 supervisor 删掉,或者用 B 脚本的备份回滚)。真要从 B 退回 A,最干净是用 B 脚本留的备份 cp argo.bak.b.XXXX /etc/init.d/argo 然后 restart。

## 注意事项

- 重启期间隧道会短暂断连几秒，属正常现象。
- 不要重新运行 bash sing-box.sh 或 sb -d 等改参数操作：这些会重写 /etc/init.d/argo，把补丁冲掉。若重写过，重新执行一次本脚本即可补回。
- 验证是否彻底修复：过几小时查看日志，不再出现 has been updated 即正常。

## 适用环境

Alpine Linux + openrc + fscarmen sing-box 一键脚本部署的固定（非临时）Argo 隧道。
