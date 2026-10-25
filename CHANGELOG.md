# 更新日志

格式参照 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)；
项目暂未启用版本号，按日期分组，最新在前。

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
