<div align="center">

# 🏠 home-sftp-frp

**家庭 SFTP 公网直传方案**

让外网用户安全地把文件传到你家里的 Windows 电脑 —— 无需公网 IP、无需路由器端口映射、无需暴露家庭网络

[![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20Ubuntu-blueviolet)](#-架构)
[![frp](https://img.shields.io/badge/frp-v0.71.1-FF4A65?logo=githubactions&logoColor=white)](https://github.com/fatedier/frp)
[![Bash](https://img.shields.io/badge/Bash-5%2B-4EAA25?logo=gnu-bash&logoColor=white)](#-项目结构)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207.x-5391FE?logo=powershell&logoColor=white)](#-项目结构)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Stars](https://img.shields.io/github/stars/zhaoqian-dong/home-sftp-frp?style=social)](https://github.com/zhaoqian-dong/home-sftp-frp/stargazers)

[✨ 功能特性](#-功能特性) · [🏗 架构](#-架构) · [🚀 快速开始](#-快速开始) · [📤 给上传者的一页](#-给上传者的一页) · [🔐 安全设计](#-安全设计) · [❓ 排障](#-常见排障)

</div>

---

## 📖 这是什么

在外地的同事、朋友或自动化设备需要往你家里传文件？

本项目提供**一套开箱即用的自动化脚本**，把家里的 Windows 电脑变成一台 SFTP 服务器，
并通过一台便宜的公网 VPS 反向代理到互联网。每个上传者拥有独立账号，
登录即进入自己的 `/upload` 目录并被 chroot 隔离——互相看不到对方的文件，也看不到你系统里的任何内容。

> 组合了 GitHub 上久经考验的成熟组件：
> [frp](https://github.com/fatedier/frp)（90k+ ⭐ 反向代理）· Windows 内置 OpenSSH Server ·
> [WinSW](https://github.com/winsw/winsw)（Windows 服务包装）· [WinSCP](https://winscp.net)（图形客户端）

## ✨ 功能特性

- 🔒 **chroot 严格隔离** —— 每账号一个 `ChrootDirectory` + NTFS ACL 断继承，账号间互不可见
- 🙈 **家庭网络零暴露** —— frpc 只发起出站连接，家里不开任何入站端口，上传者只见 VPS IP
- 🔐 **多层加密认证** —— frp 强制 TLS + 随机 token；SFTP 走标准 SSH 加密
- 🩹 **断线自愈** —— frp 心跳自动重连 + 进程内断线重登 + Windows 服务崩溃自动重启 + 开机自启，断电恢复即恢复服务
- ⚡ **双端一键部署** —— VPS 端一条 Bash、家庭端一条 PowerShell，全部幂等可重跑
- 🚄 **可选 KCP 隧道** —— 丢包高的家宽/跨境线路一键切换 UDP 传输（`.env` 里 `FRP_TRANSPORT=kcp`）
- 👥 **账号全生命周期** —— 列出/创建/删除一条命令；可选 NTFS 硬配额与保留期自动清理，磁盘塞不满
- 🔔 **可选上传通知** —— 新文件到达自动 POST webhook（Server酱地址可直接用）
- 🧪 **一键自检/卸载** —— 两端自检脚本含免凭据全链路探测；幂等卸载脚本干净可逆
- 🛡 **纵深防御** —— fail2ban 防爆破、ufw 防火墙、管理面板仅回环、上传账号禁 shell/转发/TTY
- 🇨🇳 **国内网络友好** —— GitHub 下载失败自动回退国内加速镜像，腾讯云轻量服务器全程适配
- 📦 **双形态客户端** —— WinSCP 图形界面 + 命令行上传脚本，给非技术用户也能用

## 🏗 架构

```mermaid
flowchart LR
    U["👤 外网上传者<br/>WinSCP · FileZilla · sftp CLI"]
    U -- "SFTP 连接<br/>端口 6022" --> FRPS

    subgraph VPS["☁️ 公网 VPS · Ubuntu"]
        FRPS["frps<br/>:7000 控制通道<br/>:6022 对外暴露"]
    end

    FRPC -- "frpc 主动出站<br/>TLS 加密隧道" --> FRPS

    subgraph HOME["🏠 家庭 Windows"]
        FRPC["frpc<br/>WinSW 系统服务<br/>开机自启 · 崩溃重启"]
        FRPC -- "127.0.0.1:22" --> SSHD["OpenSSH Server<br/>internal-sftp"]
        SSHD --> CH["ChrootDirectory<br/>数据目录 C:/SFTPData/用户名/upload"]
    end
```

**数据流：**

1. 上传者用任意 SFTP 客户端连接 `VPS_IP:6022`（只见 VPS，不见家庭 IP）；
2. frps 通过 **TLS 加密隧道**把流量转给主动连上来的家里 frpc；
3. frpc 转发给本机 sshd 的 `internal-sftp`（公网访问家庭 22 端口的防火墙规则已收紧为仅局域网）；
4. sshd 按 `Match User` 将每个账号 chroot 到 `C:\SFTPData\<用户名>`，直接落在 `upload/` 里。

## 📦 项目结构

```
home-sftp-frp/
├── README.md                        ← 本文件
├── CHANGELOG.md                     ← 更新日志
├── LICENSE
├── .env.example                     ← 唯一配置源（复制为 .env 使用）
├── docs/
│   └── vps-rental-guide.md          ← 租服务器指南（含机型推荐与优惠链接）
├── config/                          ← 仅供参考展示；实际配置由脚本内嵌模板生成
│   ├── frps.toml.template
│   └── frpc.toml.template
└── scripts/
    ├── setup-vps.sh                 ← ① VPS 端一键部署（Ubuntu，root 运行）
    ├── check-vps.sh                 ← ⑥ VPS 端一键自检
    ├── uninstall-vps.sh             ← ⑦ VPS 端一键卸载
    └── windows/
        ├── setup-home-windows.ps1   ← ② 家庭 Windows 一键部署（管理员）
        ├── add-sftp-user.ps1        ← ③ 创建/重置上传账号（可反复执行）
        ├── list-sftp-users.ps1      ← ③b 列出全部账号与磁盘占用
        ├── remove-sftp-user.ps1     ← ③c 删除账号（数据可选删）
        ├── check-home.ps1           ← ⑥b 家庭端一键自检（含全链路探测）
        ├── uninstall-home.ps1       ← ⑦b 家庭端一键卸载
        ├── cleanup-uploads.ps1      ← 定时任务模板：保留期清理（由 ② 自动安装）
        ├── notify-upload.ps1        ← 定时任务模板：上传通知（由 ② 自动安装）
        ├── setup-client.ps1         ← ④ 你的 Windows 客户端配置（装 WinSCP + 桌面工具）
        └── upload.ps1               ← 命令行上传（免 GUI）
```

## 🚀 快速开始

### 第 0 步 · 准备配置

```bash
cp .env.example .env
```

先只填 `VPS_IP=`（租完服务器就有），其余项在对应步骤补齐。
**同一份 `.env` 之后会同时放到 VPS 和家庭 Windows 上，是唯一的配置来源。**

可选进阶（不配置也能正常用）：

- `FRP_TRANSPORT=kcp`：隧道改走 UDP，丢包高的家宽/跨境线路吞吐更好
  （切换后需在 VPS 云防火墙额外放行 **UDP** 控制端口）；
- `SFTP_BANDWIDTH_LIMIT=5MB`：限制单个上传者的带宽，防止占满 VPS/家庭上行；
- `SFTP_USER_QUOTA_GB=10`：每个上传账号的 NTFS 硬配额（GB），防止塞满家庭磁盘；
- `SFTP_RETENTION_DAYS=30`：上传文件保留期，到期由家庭端定时任务（每天 03:30）自动清理；
- `UPLOAD_NOTIFY_WEBHOOK=`：新文件到达通知（每 5 分钟检查，POST JSON，Server酱地址可直接用）。

### 第 1 步 · 租一台 VPS

照着 [docs/vps-rental-guide.md](docs/vps-rental-guide.md) 操作，推荐：

| 机型 | 配置 | 价格 | 适合 |
|---|---|---|---|
| 腾讯云轻量应用服务器 | 2核2G | 99 元/年 | 只跑 frp 反代，本项目够用 |
| 腾讯云轻量应用服务器 | 2核4G | 199 元/年 | 除 frp 外还想跑其他服务 |

👉 [新用户特惠入口](https://cloud.tencent.com/act/cps/redirect?redirect=2446&cps_key=d579dcb5b5e80978383f637d05d3f71b&from=console)（选 Ubuntu 24.04 LTS 镜像，地域国内即可——纯 IP+TCP 用途无需备案）

⚠️ **最容易漏的一步**：轻量服务器控制台 → 防火墙 → 放行 TCP `22 / 7000 / 6022`
（云端防火墙与系统 ufw 是两道独立关卡，脚本只能配置后者）。

### 第 2 步 · VPS 一键部署

```bash
scp scripts/setup-vps.sh .env root@<VPS_IP>:/root/
ssh root@<VPS_IP>
bash setup-vps.sh
```

自动完成：安装 frps → systemd 服务 → fail2ban 防爆破 → ufw 防火墙。
若 `.env` 里 `FRP_TOKEN` 留空，脚本会**自动生成并打印**——回填到本地 `.env` 即可。

### 第 3 步 · 家庭 Windows 一键部署

把 `scripts/windows/` 整个目录 + `.env` 放到同一文件夹，管理员 PowerShell 执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\setup-home-windows.ps1
```

自动完成：安装内置 OpenSSH Server（SFTP 端）→ 防火墙收紧为仅局域网 →
建 `C:\SFTPData` → 安装 frpc 并生成配置 → 用 WinSW 注册为 Windows 服务。

### 第 4 步 · 创建上传账号（每人一个，可反复执行）

```powershell
powershell -ExecutionPolicy Bypass -File .\add-sftp-user.ps1 -UserName zhangsan
```

脚本打印该账号的地址 / 用户名 / 密码，发给对方（建议走私聊）。
账号再跑一次同样命令即重置密码。账号能力边界：**只能 SFTP、只能进自己的 `/upload`、
被 chroot 锁定、不能转发端口、不能登录 shell**。
后续管理：`.\list-sftp-users.ps1` 查看全部账号与磁盘占用；
`.\remove-sftp-user.ps1 -UserName zhangsan` 删除账号（加 `-DeleteData` 连数据一起删）。

### 第 5 步 · 客户端配置与测试

在你平时用的 Windows 上（管理员）：

```powershell
powershell -ExecutionPolicy Bypass -File .\setup-client.ps1
```

桌面生成 `Home-SFTP` 文件夹：双击 **连接SFTP.cmd** 打开 WinSCP 图形界面，
或命令行 `.\upload.ps1 -Path C:\data\xxx.zip` 上传。
首次连接会提示接受主机指纹，输入 y / 点"是"，仅一次。

<details>
<summary><b>✅ 部署完成自检清单（点开逐项走一遍）</b></summary>

> **一键版**：VPS 上 `bash check-vps.sh`、家庭 Windows 上 `.\check-home.ps1`，
> 自动检查下面全部项目，并含免凭据全链路探测（`.\check-home.ps1 -UploadTest`
> 再用真实账号传删一个测试文件）。手工逐项排查用下面的命令：

```bash
# VPS 上：frps 在监听
ss -tlnp | grep -E ':(7000|6022)'
systemctl status frps --no-pager
# 若启用了 kcp（FRP_TRANSPORT=kcp）：UDP 7000 也应在监听
ss -ulnp | grep 7000
```

```powershell
# 家庭 Windows 上：frpc 已连接（日志应有 login to server success）
Get-Content 'C:\Program Files\frp\frpc.log' -Tail 20
Get-Service frpc, sshd
```

最后：任选一种客户端用上传账号连 `sftp://<VPS_IP>:6022`，拖一个文件进去，
到家庭 `C:\SFTPData\<用户名>\upload\` 确认文件出现 —— 全链路即通。

</details>

## 📤 给上传者的一页

> 复制下面这段发给对方即可，对方不需要安装本项目任何脚本。

> **往我家传文件的方法**
>
> | 项 | 值 |
> |---|---|
> | 地址 | `<VPS_IP>` |
> | 端口 | `6022` |
> | 协议 | SFTP（不是 FTP） |
> | 用户/密码 | （另行私发） |
>
> - **WinSCP**（推荐）：[winscp.net](https://winscp.net) 下载 → 新建会话填上面四项 →
>   文件协议选 SFTP → 登录（首次提示"未知主机密钥"点"是"）→ 拖拽上传
> - **FileZilla**：站点管理器 → 协议选 SFTP → 填上面四项
> - **命令行**（Win10/11 自带）：`sftp -P 6022 用户名@<VPS_IP>`，`put 文件名` 上传
>
> 登录后你只能看到自己的 `/upload` 目录。大文件速度取决于你的上传带宽与线路。

## 🔐 安全设计

| 层 | 措施 |
|---|---|
| 传输 | frpc↔frps 强制 TLS；对外是标准 SSH/SFTP 加密 |
| 认证 | frp token（32 位随机）；SFTP 每账号独立密码；VPS SSH 建议 key 登录 |
| 隔离 | 每账号 `ChrootDirectory` 锁定自己目录 + NTFS ACL 断继承，账号间互不可见 |
| 权限 | 上传账号是非管理员本地用户，禁 shell/端口转发/TTY，密码永不过期但不可自改 |
| 暴露面 | 家庭 22 端口仅限局域网；VPS 仅开放 22/7000/6022；frp 管理面板仅回环 |
| 爆破防护 | fail2ban（VPS sshd 5 次失败封 1 小时）；上传账号走 chroot 无法触碰其他服务 |

**已知限制（如实说明）：**

- 家庭电脑睡眠会中断服务：脚本已设置**接通电源时永不睡眠/休眠**；
  笔记本用电池供电时仍按原策略（合盖/低电会睡），建议插电使用；
  另建议设置 Windows 更新"使用时段"，避免自动重启打断传输；
- Windows OpenSSH 的 `ChrootDirectory` 不做 Linux 式属主强校验，隔离实际由 NTFS ACL 保证
  （脚本已按最佳实践配置；要求 Win10 1809+ 内置 OpenSSH ≥ 7.7）；
- `setup-client.ps1` 生成的桌面工具内含明文密码（个人机便利性取舍），请勿转发，
  给上传者只发上面的说明文本；
- 所有流量过 VPS，速度上限 ≈ VPS 带宽（轻量套餐常见 3~6 Mbps，详见[租赁指南](docs/vps-rental-guide.md)）。

## ❓ 常见排障

| 现象 | 原因与处理 |
|---|---|
| 上传者连接超时 | 九成是**腾讯云控制台防火墙没放行 6022/7000**；其次检查 `.env` 端口与脚本输出一致 |
| frpc 日志报 auth failed | 两端 `FRP_TOKEN` 不一致：确认 `.env` 已回填并重跑两端脚本（或手动同步 frps.toml/frpc.toml 后重启服务） |
| frpc 日志报 connect server timeout | VPS 侧 7000 未放行，或 VPS 宕机/过期；kcp 模式下 **UDP** 7000 与 TCP 是两条规则，都要放行 |
| VPS 恢复后家里迟迟没重连 | 旧配置的 frpc 登录失败即退出、WinSW 最长 1 小时才重试：重跑 `setup-home-windows.ps1` 升级配置（现含 `loginFailExit = false`，进程内自动重连） |
| frpc 连上但 SFTP 登录失败 | 家庭 sshd 没起来：`Get-Service sshd`；或账号密码错：重跑 `add-sftp-user.ps1` 重置 |
| 能登录但看不到 upload | `C:\SFTPData\<用户名>\upload` 被手动改动：重跑 `add-sftp-user.ps1` 修复 |
| 传输速度只有几百 KB/s | 正常：受 VPS 带宽限制（见[租赁指南](docs/vps-rental-guide.md)第五节），可升级带宽 |
| 家庭重启后没恢复 | frpc 与 sshd 均为开机自启；若仍不通看 `Get-Service frpc` 与日志，必要时 `Restart-Service frpc` |
| 上传者写入报错、传不上 | 触发了账号的 NTFS 硬配额上限（配置过 `SFTP_USER_QUOTA_GB`）：家庭端 `.\list-sftp-users.ps1` 查用量，腾出空间或调大 `.env` 配额后重跑 `add-sftp-user.ps1` |
| 配了通知但收不到推送 | 任务在不在：`Get-ScheduledTask home-sftp-frp-notify`；手动跑一次 `C:\ProgramData\home-sftp-frp\notify-upload.ps1` 看报错；注意每账号**首次只建基线**，之后有新增才推 |

## 🧰 日常维护

<details>
<summary><b>家庭 Windows（PowerShell）</b></summary>

```powershell
Restart-Service frpc                                  # 重启隧道
Get-Content 'C:\Program Files\frp\frpc.log' -Tail 50  # 看日志
.\add-sftp-user.ps1 -UserName lisi                    # 加账号
.\add-sftp-user.ps1 -UserName zhangsan -Password 'New12345'   # 重置密码
.\list-sftp-users.ps1                                 # 账号列表与磁盘占用
.\remove-sftp-user.ps1 -UserName lisi                 # 删除账号
.\check-home.ps1                                      # 一键自检（含全链路探测）
.\check-home.ps1 -UploadTest                          # 自检 + 真实账号传测试文件
Get-ScheduledTask home-sftp-frp-*                     # 可选定时任务（配置后才有）
Get-Content 'C:\ProgramData\home-sftp-frp\cleanup.log' -Tail 20  # 清理日志（配置保留期后才有）
```

</details>

<details>
<summary><b>VPS（Ubuntu）</b></summary>

```bash
journalctl -u frps -n 50          # frps 日志
systemctl restart frps
vim /etc/frp/frps.toml            # 改完记得 systemctl restart frps
fail2ban-client status sshd       # 查看封禁列表
bash check-vps.sh                 # 一键自检
```

</details>

<details>
<summary><b>可选功能：配额 / 保留期清理 / 上传通知</b></summary>

三个功能均由 `.env` 开关 + 重跑 `setup-home-windows.ps1` 生效（见下方"升级 / 换配置"）。

**定时任务**

| 任务名 | 触发 | 作用 |
|---|---|---|
| `home-sftp-frp-cleanup` | 每天 03:30 | 删除超过 `SFTP_RETENTION_DAYS` 天的上传文件（只删文件、保留目录，不可恢复） |
| `home-sftp-frp-notify` | 每 5 分钟 | 对比各账号的"文件数：总字节"，有新增就 POST webhook |

生成的任务脚本与状态都在 `C:\ProgramData\home-sftp-frp\`（ACL 仅 SYSTEM/管理员）：
`cleanup-uploads.ps1` / `notify-upload.ps1` 是 .env 值的固化副本（改 .env 重跑即更新），
`cleanup.log` 是清理日志，`notify-state.json` 是通知基线状态（损坏会自动重建）。

```powershell
Get-ScheduledTask home-sftp-frp-*                                          # 查看任务
& 'C:\ProgramData\home-sftp-frp\notify-upload.ps1'                         # 手动试跑通知
& 'C:\ProgramData\home-sftp-frp\cleanup-uploads.ps1'                       # 手动试跑清理
```

**上传通知（webhook）**

- `.env` 里 `UPLOAD_NOTIFY_WEBHOOK=` 填推送地址并重跑部署脚本；Server酱直接填
  `https://sctapi.ftqq.com/<你的SendKey>.send` 即可收推送；
- 每 5 分钟检查一次，**仅当某账号总字节数增长**时推送（对方删除文件不打扰）；
- 每个账号首次被观察到时只记录基线、不通知——已存在的历史文件不会触发轰炸；
- POST 为 UTF-8 JSON，其他 webhook 服务按需取用字段：

```json
{
  "title": "家庭 SFTP 收到新文件",
  "desp": "账号 zhangsan：新增 200.5 MB（现共 3 个文件 / 1024.0 MB）",
  "user": "zhangsan",
  "new_bytes": 210239488,
  "total_files": 3,
  "total_bytes": 1073741824
}
```

</details>

<details>
<summary><b>升级 / 换配置 / 卸载</b></summary>

- **升级 frp**：改 `.env` 的 `FRP_VERSION`（默认 0.71.1），两端重跑即可（旧配置自动备份保留）；
- **换 token**：改 `.env` 的 `FRP_TOKEN` → VPS 重跑 `setup-vps.sh` → 家庭重跑 `setup-home-windows.ps1`；
- **换 SFTP 公网端口**：改 `.env` 的 `SFTP_PUBLIC_PORT` → 家庭重跑步骤 3 脚本 → VPS 控制台防火墙放行新端口；
- **改配额/保留期/通知**：改 `.env` 对应项 → 家庭重跑 `setup-home-windows.ps1`（新账号即带配额；定时任务自动增删）；
- **卸载 VPS**：`bash uninstall-vps.sh`（`--yes` 免确认；保留 ufw 与 fail2ban 本体及 22 端口规则）
- **卸载家庭 Windows**：`powershell -ExecutionPolicy Bypass -File .\uninstall-home.ps1`
  （`-Force` 跳过确认；`-DeleteData` 连数据目录与上传账号一起清除）

</details>

## 🙏 致谢

本项目站在这些优秀开源项目的肩膀上：

| 项目 | 作用 |
|---|---|
| [fatedier/frp](https://github.com/fatedier/frp) | 高性能反向代理，内网穿透核心 |
| [PowerShell/Win32-OpenSSH](https://github.com/PowerShell/Win32-OpenSSH) | Windows 内置 OpenSSH，提供 SFTP 服务端 |
| [winsw/winsw](https://github.com/winsw/winsw) | 把 frpc 包装为可靠的 Windows 服务 |
| [winscp/winscp](https://github.com/winscp/winscp) | Windows 下最好用的 SFTP 图形客户端 |

## 📄 许可证

[MIT](LICENSE) © 2026
