# 更新日志

格式参照 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)；
项目暂未启用版本号，按日期分组，最新在前。

## 2026-10-26 · 仓库工程化

- **CI（GitHub Actions）**：三个 job——`shellcheck`（bash）、`PSScriptAnalyzer`
  （PowerShell，项目级豁免清单见 `PSScriptAnalyzerSettings.psd1`，每条豁免附理由）、
  frp 配置验证（渲染两端内嵌模板 → 真实 frpc/frps 二进制 `verify`）；
- **模板防漂移**：`config/` 参考模板与脚本内嵌模板的一致性由 CI 逐键强制校验
  （`tests/check_templates.py`；历史上 `log.*` 位置问题即此类漂移），模板头注释同步说明；
- **桌面工具凭据升级**：`setup-client.ps1` 优先把站点写入 WinSCP 加密存储
  （WinSCPnet 加密函数写入注册表，仅当前 Windows 用户可解），生成的 连接SFTP.cmd 与
  upload.ps1 不再内嵌明文密码；加密创建失败时自动回退旧的 URL 内嵌方案；
- 新增 `SECURITY.md`（漏洞报告渠道与范围界定）、`CONTRIBUTING.md`（风格约定、
  测试要求、真机教训清单）、`README.en.md` 英文版（中英互链）。

## 2026-10-26 · 真机验收与修复

在 Parallels Windows 11 ARM64（中文版专业版）+ 腾讯云 Ubuntu 22.04 真机完成端到端验收：
部署七步全通、账号创建/重置、secedit 拒绝登录、check-home 全绿（15/0/0）、
公网全链路真实上传（外网 → 云防火墙 → frps → 隧道 → chroot /upload）、删除与卸载回程。
验收暴露并修复 4 个静态检查无法发现的 bug：

- **secedit /configure 在真实 Windows 上必然失败**：改用全新数据库文件
  （系统已有 secedit.sdb 会直接报参数错误）并经由 `cmd /c` 调用
  （PowerShell 直调无论何种参数都静默返回 1）；
- **param 默认值中的 `$PSScriptRoot` 真机实测可能为空**：8 个脚本的 `.env`
  默认路径改为脚本体解析 + `$MyInvocation` 兜底；
- **重置账号流程中途失败**：`Set-LocalUser` 误用了只存在于 `New-LocalUser` 的
  `-UserMayNotChangePassword` 参数，更正为 `-UserMayChangePassword:$false`；
- **Guest 默认拒绝交互登录条目可能丢失**：合并时将导出中的裸账户名翻译为 SID
  （全新 db 下 secedit 解析不了裸名），并兜底确保 `*S-1-5-32-546` 存在。

其他：

- `Invoke-Download` 支持复用 `%TEMP%` 中已存在且 sha256 校验通过的文件，
  "手动下载后重跑"的离线路径正式落地（弱网环境可用）；
- ARM64 兼容性结论：Windows 11 ARM64 经 x64 模拟运行 amd64 版 frpc 全链路可用，
  已记录到 README 已知限制。

## 2026-10-26 · 安全加固

- **frps 端口白名单**：`allowPorts` 锁定到 SFTP 公网端口 + `maxPortsPerClient = 1`——
  token 泄露时攻击者也无法在 VPS 上另开反向代理端口当跳板；
- **下载完整性**：frp（linux amd64/arm64、windows zip）、WinSW、OpenSSH 独立版的官方
  sha256 固化进脚本逐源校验，不符即丢弃换源；镜像仅在哈希可得时作为回退，
  未内置哈希的版本自动从官方 `frp_sha256_checksums.txt` 获取，拿不到则禁用镜像仅 GitHub 直连；
- **上传账号只许 SFTP**：secedit 给 sftpusers 组写入"拒绝本地/远程交互登录"（合并既有
  SeDeny 条目、幂等），账号无法在 Windows 登录界面或 RDP 登录；
- **爆破缓解**：家庭 sshd Match 块加 `MaxAuthTries 3`；22/6022 改 `ufw limit` 连接限速
  （长连接不受影响）；新增可选机器级账户锁定 `SFTP_LOCKOUT_THRESHOLD`（全机生效，默认关闭）；
- **VPS 自动安全更新**：安装并启用 unattended-upgrades；
- `check-vps.sh` 新增 allowPorts 与自动更新检查；`uninstall-vps.sh` 兼容删除 limit/allow 两种规则。

## 2026-10-26 · 功能扩展

- **账号全生命周期**：新增 `list-sftp-users.ps1`（账号/占用/配额一览，游离成员告警）与
  `remove-sftp-user.ps1`（删用户、清配额与 sshd 配置块；数据目录默认保留，`-DeleteData` 连数据删）；
- **磁盘保护**（.env 可选，重跑家庭端部署脚本生效）：
  - `SFTP_USER_QUOTA_GB`：每个上传账号 NTFS 硬配额（`fsutil quota`，90% 告警线）；
  - `SFTP_RETENTION_DAYS`：注册每天 03:30 的 SYSTEM 定时任务，自动清理过期上传文件（只删文件、保留目录，带日志）；
- **上传通知**：`UPLOAD_NOTIFY_WEBHOOK` 每 5 分钟轮询，新文件到达 POST UTF-8 JSON
  （含 `title`/`desp`，Server酱地址可直接用）；首次只建基线不通知，删除不打扰，状态损坏自动重建；
- **FRP_VERSION 移入 `.env`**：升级 frp 只改一处，两端脚本共用；
- **一键自检**：`check-vps.sh` / `check-home.ps1`（服务、防火墙、配置一致性、隧道连通；
  家庭端含免凭据全链路探测，可选 `-UploadTest` 真实传删测试文件）；
- **一键卸载**：`uninstall-vps.sh`（保留 ufw/fail2ban 本体与 22 端口规则）、
  `uninstall-home.ps1`（数据与账号默认保留，`-DeleteData` 全清）。

## 2026-10-25 · 可靠性与性能

- **断线自愈**：frpc 增加 `loginFailExit = false`——VPS 重启或短暂宕机后在进程内持续重连，
  不再依赖 WinSW 失败计数（最长 1 小时才重试）；
- **可选 KCP 隧道**：`.env` 配 `FRP_TRANSPORT=kcp` 走 UDP，丢包高的家宽/跨境线路吞吐更好
  （frps 加 `kcpBindPort` 与 TCP 同端口；ufw 放行 UDP；部署摘要按模式提示云防火墙规则）；
- **断点续传**：两个上传脚本（仓库版 + 桌面生成版）启用 WinSCP `put -resume`；
- **可选限速**：`SFTP_BANDWIDTH_LIMIT` 限制单个上传者带宽（frpc 代理级 `transport.bandwidthLimit`）；
- **电源加固**：家庭端部署脚本新增"接通电源时永不睡眠/休眠"（`powercfg`），
  电池设备提示例外，并提醒设置 Windows 更新"使用时段"。

### 修复

- **frpc.toml 模板**：`log.*` 原写在 `[[proxies]]` 块之后，按 TOML 语义会被解析为 proxy 子字段，
  frp v0.71.1 严格解码报 `unknown field "log"` 导致部署校验失败；已移至根级（`[[proxies]]` 之前）。
