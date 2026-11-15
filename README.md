# argo-autoupdate-fix

修复 fscarmen sing-box 脚本部署的 Argo 隧道在 Alpine/openrc 环境下「过一段时间自动关闭、且开启失败」的问题。提供两套修复方案和一个备份回滚工具。

## 问题现象

用 `bash <(wget -qO- https://raw.githubusercontent.com/fscarmen/sing-box/main/sing-box.sh)` 部署 reality + hysteria2 + vless Argo 节点，其中固定隧道一开始正常，运行一段时间后 Argo 自动关闭，手动开启失败。

## 根本原因

三个因素叠加：

1. **cloudflared 自动更新**：独立二进制作为服务运行时，内置 autoupdate 默认开启，每隔几小时检查新版本，一旦有更新就下载替换自身并以退出码 11 主动退出，依赖 init 系统重新拉起。
2. **openrc 不自动拉起**：Alpine 的 openrc 服务（`/etc/init.d/argo`）用 `command_background="yes"` 启动，没有 supervisor，cloudflared 退出后不会自动重启，隧道就此停摆。
3. **fscarmen 脚本的疏漏**：脚本给固定隧道（config / token 模式）生成的服务命令**没有带 `--no-autoupdate`**（只有临时隧道 `--url` 模式带），所以固定隧道用户必然中招。

日志特征（`/etc/sing-box/logs/argo.log`）：

    cloudflared has been updated version=2026.11.0
    Initiating shutdown error="cloudflared has been updated to version 2026.11.0"
    Tunnel server stopped

> 注：内存紧张不是本次停机的主因。排查时 `oom_kill` 为 0，没有进程被 OOM 杀掉。

## 两套方案

| | argo-patch.sh（A） | argo-supervise.sh（B） |
|---|---|---|
| 自动更新 | 禁用 | 保留 |
| 靠什么续命 | 不退出，一劳永逸 | 退出后 supervisor 5 秒内拉起 |
| 附带好处 | 版本冻结 | 进程崩溃也能自动复活 |
| 改动 | 加 `--no-autoupdate` | 换成 `supervisor="supervise-daemon"` + `respawn_delay=5` + `respawn_max=0` |

Cloudflare 官方 openrc 服务模板用的是方案 B：`supervisor="supervise-daemon"`，让 cloudflared 更新退出后自动重启加载新版。方案 A 更省事，代价是版本永久冻结。按需选择。

## 用法

三个脚本都需 root 权限。Alpine 默认没有 bash，用管道 `| sh`：

    # 方案 A：禁用自动更新
    wget -qO- https://raw.githubusercontent.com/qianhu111/argo-autoupdate-fix/main/argo-patch.sh | sh

    # 方案 B：保留自动更新 + supervisor 保活
    wget -qO- https://raw.githubusercontent/qianhu111/argo-autoupdate-fix/main/argo-supervise.sh | sh

    # 回滚：列出备份，交互选编号
    sh argo-restore.sh
    # 或直接还原第 2 个备份
    sh argo-restore.sh 2

curl 版（同样零残留）：

    curl -fsSL https://raw.githubusercontent.com/qianhu111/argo-autoupdate-fix/main/argo-patch.sh | sh

装了 bash 的机器也可用进程替换写法：

    bash <(wget -qO- https://raw.githubusercontent.com/qianhu111/argo-autoupdate-fix/main/argo-patch.sh)

> `wget -qO-` 的 `-O-` 表示输出到 stdout 不落盘，管道直接喂给 sh，运行完无文件残留。只有 `wget -O 文件名` 才会落地。

## 脚本行为

所有脚本都遵循：检查环境（root / openrc / 服务文件），不符合直接退出不乱改；修改前按时间戳备份；幂等设计，重复运行结果一致；清理残留进程与 openrc 僵死状态（zap + 删 pidfile）；重启并验收（服务状态、关键配置行、进程、日志）。

**argo-restore.sh** 额外会扫描所有 `argo.bak*` 备份并标注状态（A 态 / B 态 / 混合态 / 原始态），还原前自动另存当前状态为 `argo.bak.pre-restore.XXXX`，选错也能反悔。

## 互转与回滚

两个脚本改的是同一个文件 `/etc/init.d/argo`，但能力不对称：

- **B 能覆盖 A**：从 A 切到 B，直接跑 `argo-supervise.sh`，它会删掉 `--no-autoupdate` 并重建 supervisor 配置。
- **A 盖不干净 B**：从 B 切回 A，别直接跑 A（会残留 supervisor 行），用 `argo-restore.sh` 选 B 运行前的备份，或手动：

      cp /etc/init.d/argo.bak.b.XXXX /etc/init.d/argo
      rc-service argo restart

备份后缀区分：`argo.bak.XXXX` 是 A 脚本留的，`argo.bak.b.XXXX` 是 B 脚本留的。想回到哪个状态就选对应那版。

## 注意事项

- 重启期间隧道会短暂断连几秒，属正常现象。
- **不要重新运行 `bash sing-box.sh` 或 `sb -d` 等改参数操作**：这些会重写 `/etc/init.d/argo`，把补丁冲掉。若重写过，重新执行对应脚本即可补回。
- 验证是否彻底修复：过几小时查看日志，方案 A 不再出现 `has been updated`；方案 B 出现 `has been updated` 后几秒内会重新 `Registered tunnel connection`，均属正常。
- 用 `curl -O` / `wget -O` 下载到本地的脚本文件是真实落盘的，用完可自行删除。

## 适用环境

Alpine Linux + openrc + fscarmen sing-box 一键脚本部署的固定（非临时）Argo 隧道。方案 B 另需 `supervise-daemon`（openrc 0.21+ 自带，Alpine 3.x 均满足）。
