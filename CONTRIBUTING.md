# 贡献指南（Contributing）

感谢关注本项目。这是一套"脚本即产品"的仓库：没有编译产物，**脚本本身就是交付物**，
因此对正确性与风格的要求都围绕脚本展开。

## 环境准备

| 工具 | 用途 | 本地安装 |
|---|---|---|
| bash / shellcheck | VPS 端三个脚本的语法与静态检查 | `brew install shellcheck` |
| pwsh + PSScriptAnalyzer | Windows 端十个脚本的静态检查 | `brew install --cask powershell` 后 `Install-Module PSScriptAnalyzer` |
| frp 二进制 | 渲染内嵌模板后跑 `frpc/frps verify` | 从 [frp releases](https://github.com/fatedier/frp/releases) 下载，或交给 CI |

提交前在本地跑一遍 CI 的三件事（CI 在 `.github/workflows/ci.yml`，对 PR 同样生效）：

```bash
shellcheck -x scripts/*.sh
pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path scripts/windows -Recurse -Settings PSScriptAnalyzerSettings.psd1"
bash tests/render-frps.sh && pwsh -File tests/render-frpc.ps1
python3 tests/check_templates.py
```

## 代码约定

- **注释与输出用中文**，生成给 cmd / WinSCP 用的注释除外（ASCII，规避代码页问题）；
- **`.ps1` 必须带 UTF-8 BOM**——无 BOM 时中文版 Windows PowerShell 5.1 会按 ANSI 读取导致乱码/解析错误；
- 脚本必须**幂等可重跑**：重跑部署脚本应得到一致结果，不重复创建、不破坏用户数据；
- 破坏性操作（删目录、删账号）必须**显式开关或交互确认**，默认保留数据；
- 参数默认值里**不要用 `$PSScriptRoot`**（真机实测 Windows PowerShell 5.1 下可能为空），
  在脚本体中解析并配 `$MyInvocation` 兜底——见各脚本 `$EnvFile` 的写法；
- 调用 `secedit /configure` 必须用**全新数据库 + 经 `cmd /c`**，原因见
  `Grant-SftpGroupNoInteractiveLogon` 的注释（真机实测教训）；
- 改动 frp 配置生成逻辑时，同步更新 `config/` 参考模板——**CI 会做两份模板的
  逐键一致性校验**，漂移会挂；
- 下载外部二进制必须固化官方 sha256 并逐源校验，第三方镜像仅在哈希可得时作为回退。

## 提交规范

- Commit message 用 conventional commits + 中文描述（`feat:` / `fix:` / `docs:` …）；
- 涉及用户可感知变化的 PR/commit 需同步更新 `CHANGELOG.md`（按日期分组置顶）；
- README 的项目结构树、安全设计表如受影响需同步。

## 测试要求

- 纯语法/渲染类改动：本地跑绿上述 CI 三件套即可；
- **部署逻辑改动**（生成配置、注册服务、改策略）：必须在真实 Windows（虚拟机亦可）
  上跑通 `setup-home-windows.ps1` → `add-sftp-user.ps1` → `check-home.ps1`，
  并在 PR 描述中注明测试环境；历史教训见 CHANGELOG 的"真机验收与修复"一节——
  静态检查全绿不等于真机能跑。
