<#
.SYNOPSIS
    家里 Windows 机器一键配置：SFTP 服务端（内置 OpenSSH Server）+ frpc 反向隧道客户端

.DESCRIPTION
    步骤：
      1. 安装/启用 Windows 内置 OpenSSH Server（sshd，提供 SFTP 服务）
         并收紧 sshd 防火墙规则为仅限局域网（公网访问一律走 frp 隧道）
      2. 创建 SFTP 数据根目录 + sftpusers 用户组，并做 NTFS ACL 加固
      3. 安装 frpc 到 C:\Program Files\frp 并生成 frpc.toml
      4. 用 WinSW 把 frpc 注册为 Windows 服务（开机自启、崩溃自动重启）
      5. 电源设置（接通电源时永不睡眠）+ 系统更新使用时段提醒
      6. 可选定时任务：上传保留期清理 / 新文件 webhook 通知（按 .env 配置）
      7. 状态检查与摘要

    运行要求：管理员 PowerShell；本脚本与 .env 放在同一目录。
    家里路由器无需任何端口映射（frpc 只发起出站连接）。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\setup-home-windows.ps1
#>

param(
    [string]$EnvFile
)

$ErrorActionPreference = 'Stop'
# .env 默认路径在脚本体里解析：param 默认值中的 $PSScriptRoot 在 Windows
# PowerShell 5.1 真机实测可能为空，body 中配合 $MyInvocation 兜底才可靠
if (-not $EnvFile) {
    $dir = $PSScriptRoot
    if (-not $dir) { $dir = Split-Path -Parent $MyInvocation.MyCommand.Path }
    $EnvFile = Join-Path $dir '.env'
}

$FrpVersion   = '0.71.1'   # 默认 frp 版本（可被 .env 的 FRP_VERSION 覆盖）
$WinSwVersion = '2.12.0'   # WinSW（Windows 服务包装器）版本
$FrpDir       = 'C:\Program Files\frp'
$SshdConfig   = "$env:ProgramData\ssh\sshd_config"
$SftpGroup    = 'sftpusers'

# ---------------------------------------------------------------- 通用工具
function Write-Info  { param($m) Write-Host "[INFO] $m" -ForegroundColor Green }
function Write-Warn2 { param($m) Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Write-Step  { param($n, $m) Write-Host "`n==> [$n/7] $m" -ForegroundColor Cyan }
function Write-Fail  { param($m) Write-Host "[ERROR] $m" -ForegroundColor Red; exit 1 }

# 运行原生命令并返回退出码。
# 单独封装是因为 $ErrorActionPreference='Stop' 时，stderr 重定向会把
# 原生命令的错误输出包装成异常中断脚本（curl 进度条就写在 stderr）
function Invoke-Native {
    param([string]$Exe, [string[]]$CmdArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Exe @CmdArgs 2>&1 | ForEach-Object { "$_" } | Out-Null
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
}

# 从 .env 读取键值对（兼容值两边的双引号）
function Get-EnvMap {
    param([string]$Path)
    if (-not (Test-Path $Path)) { Write-Fail "未找到 .env：$Path`n请把它与脚本放在同一目录（复制 .env.example 为 .env 并填写）" }
    $map = @{}
    foreach ($line in (Get-Content -Path $Path -Encoding UTF8)) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
            $v = $Matches[2].Trim()
            if ($v.Length -ge 2 -and $v.StartsWith('"') -and $v.EndsWith('"')) {
                $v = $v.Substring(1, $v.Length - 2)
            }
            $map[$Matches[1]] = $v
        }
    }
    return $map
}

# 多源下载：GitHub 直连失败自动回退国内加速镜像（用系统自带 curl.exe）。
# 提供 $Sha256 时逐源校验，不符则丢弃换下一源 —— 镜像投毒被挡在校验之外
function Invoke-Download {
    param([string[]]$Urls, [string]$OutFile, [int]$MinBytes = 100000, [string]$Sha256 = '')
    # 目标文件已存在且校验通过时直接复用（弱网/离线：手动下载放到 %TEMP% 再重跑）
    if (Test-Path $OutFile) {
        $reuse = $false
        if ((Get-Item $OutFile).Length -ge $MinBytes) {
            if ($Sha256) {
                $actual = (Get-FileHash -Path $OutFile -Algorithm SHA256).Hash.ToLower()
                if ($actual -eq $Sha256.ToLower()) { $reuse = $true }
            } else {
                $reuse = $true
            }
        }
        if ($reuse) { Write-Info "检测到 $OutFile 已存在且校验通过，跳过下载"; return }
        Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
    }
    foreach ($u in $Urls) {
        Write-Info "下载：$u"
        $rc = Invoke-Native 'curl.exe' @('-fsSL', '--connect-timeout', '10', '--retry', '2', '-o', $OutFile, $u)
        if ($rc -ne 0 -or -not (Test-Path $OutFile) -or ((Get-Item $OutFile).Length -lt $MinBytes)) {
            Write-Warn2 "下载失败，尝试下一个源..."
            continue
        }
        if ($Sha256) {
            $actual = (Get-FileHash -Path $OutFile -Algorithm SHA256).Hash.ToLower()
            if ($actual -ne $Sha256.ToLower()) {
                Write-Warn2 "sha256 校验不符（期望 $Sha256，实际 $actual），丢弃并尝试下一个源..."
                Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
                continue
            }
            Write-Info "sha256 校验通过"
        }
        return
    }
    Write-Fail "所有下载源均失败，请检查网络；也可手动下载后放到 $env:TEMP 再重跑"
}

# 解析 frp 发布包的期望 sha256：内置版本用固化值（来源官方 frp_sha256_checksums.txt）；
# 其他版本现场从官方 checksums 获取；拿不到则返回 $null（调用方应禁用镜像、仅 GitHub 直连）
function Get-FrpZipSha256 {
    param([string]$Version, [string]$ZipName, [string]$ReleaseUrl)
    if ($Version -eq '0.71.1') {
        return 'b90074b2b6a1d792a7a40f085ac6d276bcab2d1bc60201f8a86ca53ce65ce821'
    }
    $ck = Join-Path $env:TEMP 'frp_sha256_checksums.txt'
    $rc = Invoke-Native 'curl.exe' @('-fsSL', '--connect-timeout', '10', '--max-time', '60',
        '-o', $ck, "$ReleaseUrl/frp_sha256_checksums.txt")
    if ($rc -eq 0 -and (Test-Path $ck)) {
        $line = Get-Content -Path $ck | Where-Object { $_ -match [regex]::Escape($ZipName) } | Select-Object -First 1
        if ($line) { return ($line.Trim() -split '\s+')[0] }
    }
    return $null
}

function Write-FileNoBom {
    param([string]$Path, [string]$Content)
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

# 取本机局域网 IPv4（用于打印局域网直连测试地址）
function Get-LanIp {
    $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } |
        Select-Object -First 1
    if ($ip) { $ip.IPAddress } else { '<本机局域网IP>' }
}

# 通过 secedit 给本地组写入"拒绝交互式登录"与"拒绝远程交互式登录"（RDP）权限：
# 上传账号只能走 SFTP（网络登录），无法在 Windows 登录界面或 RDP 登录。
# 做法：导出当前策略 -> 在既有 SeDeny* 值上合并本组 SID（保留 Guest 等原条目）-> 回写。
# 幂等：SID 已存在则不重复添加；只回写这两个权限项，其余策略不受影响
function Grant-SftpGroupNoInteractiveLogon {
    param([string]$GroupName)
    $sid    = (Get-LocalGroup -Name $GroupName).SID.Value
    $export = Join-Path $env:TEMP 'secedit-export.inf'
    $cfg    = Join-Path $env:TEMP 'secedit-sftp.inf'
    $db     = Join-Path $env:TEMP 'secedit-sftp.sdb'
    if ((Invoke-Native 'secedit.exe' @('/export', '/cfg', $export, '/quiet')) -ne 0) {
        throw 'secedit /export 失败'
    }
    $rights = @{}
    foreach ($right in @('SeDenyInteractiveLogonRight', 'SeDenyRemoteInteractiveLogonRight')) {
        $line = Get-Content -Path $export | Where-Object { $_ -match "^$right\s*=" } | Select-Object -First 1
        $values = @()
        if ($line) {
            foreach ($v in (($line -split '=', 2)[1].Trim() -split '\s*,\s*')) {
                if (-not $v) { continue }
                if ($v -match '^\*') { $values += $v; continue }
                # 导出里的裸账户名（如 Guest）在全新 db 下 secedit 解析不了，先翻译成 SID
                try {
                    $values += "*" + ([System.Security.Principal.NTAccount]$v).Translate(
                        [System.Security.Principal.SecurityIdentifier]).Value
                } catch { $values += $v }
            }
        }
        if ($values -notcontains "*$sid") { $values += "*$sid" }
        # Windows 默认拒绝 Guest 交互登录；防止历史版本/意外配置丢失该条目
        if ($right -eq 'SeDenyInteractiveLogonRight' -and $values -notcontains '*S-1-5-32-546') {
            $values += '*S-1-5-32-546'
        }
        $rights[$right] = ($values | Select-Object -Unique) -join ','
    }
    $nl = "`r`n"
    $inf = "[Unicode]$nl" +
        "Unicode=yes$nl" +
        "[Privilege Rights]$nl" +
        "SeDenyInteractiveLogonRight = $($rights['SeDenyInteractiveLogonRight'])$nl" +
        "SeDenyRemoteInteractiveLogonRight = $($rights['SeDenyRemoteInteractiveLogonRight'])$nl" +
        "[Version]$nl" +
        'signature="$CHICAGO$"' + $nl +
        'Revision=1' + $nl
    [System.IO.File]::WriteAllText($cfg, $inf, (New-Object System.Text.UnicodeEncoding))
    # /db 必须用全新数据库文件（secedit 自动创建）：真机实测对系统已有 secedit.sdb
    # 执行 /configure 会直接报参数错误；全新 db 只应用本 INF 中的权限项，系统其余
    # 策略不受影响（SeDeny 的既有值如 Guest 已在上方合并保留）
    if (Test-Path $db) { Remove-Item $db -Force }
    # 真机实测：PowerShell 里 & secedit.exe 直调 /configure 无论何种参数都静默返回 1
    # （/export 不受影响）；必须经由 cmd /c 调用，且 /db 用全新数据库（原因见上）
    if ((Invoke-Native 'cmd.exe' @('/c', "secedit /configure /db `"$db`" /cfg `"$cfg`" /quiet")) -ne 0) {
        throw 'secedit /configure 失败'
    }
    Remove-Item -LiteralPath $export, $cfg, $db -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- 0. 前置检查
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Fail "请以管理员身份运行 PowerShell（右键开始菜单 -> 终端(管理员)）后重试"
}

$envMap = Get-EnvMap -Path $EnvFile
$VpsIp          = $envMap['VPS_IP']
$FrpBindPort    = if ($envMap['FRP_BIND_PORT'])    { $envMap['FRP_BIND_PORT'] }    else { '7000' }
$SftpPublicPort = if ($envMap['SFTP_PUBLIC_PORT']) { $envMap['SFTP_PUBLIC_PORT'] } else { '6022' }
$FrpToken       = $envMap['FRP_TOKEN']
$SftpRoot       = if ($envMap['SFTP_ROOT'])        { $envMap['SFTP_ROOT'] }        else { 'C:\SFTPData' }
$FrpTransport   = if ($envMap['FRP_TRANSPORT'])    { $envMap['FRP_TRANSPORT'] }    else { 'tcp' }
$FrpVersion     = if ($envMap['FRP_VERSION'])      { $envMap['FRP_VERSION'] }      else { $FrpVersion }
$BandwidthLimit = $envMap['SFTP_BANDWIDTH_LIMIT']
$RetentionRaw   = $envMap['SFTP_RETENTION_DAYS']
$WebhookUrl     = $envMap['UPLOAD_NOTIFY_WEBHOOK']

if (-not $VpsIp)    { Write-Fail ".env 中 VPS_IP 为空，请先填写 VPS 公网 IP" }
if (-not $FrpToken) { Write-Fail ".env 中 FRP_TOKEN 为空，请先在 VPS 上运行 setup-vps.sh，把生成的 token 回填进 .env" }
if ($FrpTransport -notin @('tcp', 'kcp')) {
    Write-Fail ".env 中 FRP_TRANSPORT 仅支持 tcp 或 kcp（当前：$FrpTransport）"
}

# ---------------------------------------------------------------- 1. OpenSSH Server
Write-Step 1 "安装/启用 OpenSSH Server（SFTP 服务端）"

$cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' -ErrorAction SilentlyContinue |
    Select-Object -First 1
if ($cap -and $cap.State -eq 'Installed') {
    Write-Info "OpenSSH Server（系统可选功能）已安装，跳过"
} else {
    $installed = $false
    if ($cap) {
        Write-Info "通过 Windows 可选功能安装（可能需要几分钟）..."
        try {
            Add-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop | Out-Null
            $installed = $true
        } catch {
            Write-Warn2 "可选功能安装失败：$($_.Exception.Message)"
        }
    }
    if (-not $installed) {
        # 回退方案：GitHub 官方 Win32-OpenSSH 独立版
        Write-Info "回退：从 GitHub 安装 Win32-OpenSSH 独立版..."
        $sshZip = Join-Path $env:TEMP 'OpenSSH-Win64.zip'
        # 哈希来自官方 GitHub 直连下载的 v9.5.0.0p1-Beta（官方未发布 checksums 文件）
        Invoke-Download -Urls @(
            'https://github.com/PowerShell/Win32-OpenSSH/releases/download/v9.5.0.0p1-Beta/OpenSSH-Win64.zip',
            'https://gh-proxy.com/https://github.com/PowerShell/Win32-OpenSSH/releases/download/v9.5.0.0p1-Beta/OpenSSH-Win64.zip'
        ) -OutFile $sshZip -Sha256 'bd48fe985d400402c278c485db20e6a82bc4c7f7d8e0ef5a81128f523096530c'
        $sshDir = 'C:\Program Files\OpenSSH'
        if (Test-Path "$env:TEMP\OpenSSH-Win64") { Remove-Item -Recurse -Force "$env:TEMP\OpenSSH-Win64" }
        Expand-Archive -Path $sshZip -DestinationPath $env:TEMP -Force
        New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
        Copy-Item -Path "$env:TEMP\OpenSSH-Win64\*" -Destination $sshDir -Recurse -Force
        & "$sshDir\install-sshd.ps1" | Out-Null
    }
}

$sshdSvc = Get-Service sshd -ErrorAction SilentlyContinue
if (-not $sshdSvc) { Write-Fail "sshd 服务未找到，OpenSSH Server 安装失败" }

# 确保 SSH 主机密钥存在（sshd 无密钥无法启动）
$sshKeygen = @("$env:SystemRoot\System32\OpenSSH\ssh-keygen.exe", 'C:\Program Files\OpenSSH\ssh-keygen.exe') |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if ($sshKeygen -and -not (Test-Path "$env:ProgramData\ssh\ssh_host_ed25519_key")) {
    Write-Info "生成 SSH 主机密钥..."
    Invoke-Native $sshKeygen @('-A') | Out-Null
}

Set-Service -Name sshd -StartupType Automatic
if ($sshdSvc.Status -ne 'Running') { Start-Service sshd }
Write-Info "sshd 服务已启动并设为开机自启"

# 收紧防火墙：22 端口仅允许局域网访问（frp 隧道流量来自本机回环，不受影响）
if (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue) {
    Set-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -RemoteAddress LocalSubnet -Enabled True
} else {
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH SSH Server (sshd)' `
        -Direction Inbound -Protocol TCP -LocalPort 22 -RemoteAddress LocalSubnet `
        -Action Allow -Profile Any | Out-Null
}
Write-Info "防火墙已收紧：sshd 22 端口仅限局域网访问"

# ---------------------------------------------------------------- 2. SFTP 数据目录
Write-Step 2 "创建 SFTP 数据根目录与用户组"
New-Item -ItemType Directory -Force -Path $SftpRoot | Out-Null

if (-not (Get-LocalGroup -Name $SftpGroup -ErrorAction SilentlyContinue)) {
    New-LocalGroup -Name $SftpGroup -Description 'SFTP upload users (home-sftp-frp)' | Out-Null
    Write-Info "已创建本地组 $SftpGroup"
} else {
    Write-Info "本地组 $SftpGroup 已存在，跳过"
}

# 根目录断继承：仅 SYSTEM / Administrators 完全控制，sftpusers 组可读（不向下继承）。
# Windows 的 ChrootDirectory 不做 Linux 式属主强校验，隔离由 NTFS ACL 保证
$icaclsArgs = @($SftpRoot, '/inheritance:r', '/grant:r',
    '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F', "${SftpGroup}:RX")
if ((Invoke-Native 'icacls.exe' $icaclsArgs) -ne 0) { Write-Fail "icacls 设置根目录 ACL 失败" }
Write-Info "SFTP 根目录 ACL 已加固：$SftpRoot"

# 上传账号只允许 SFTP：拒绝整个组的本地登录与 RDP（组级权限，对全部成员生效）
try {
    Grant-SftpGroupNoInteractiveLogon -GroupName $SftpGroup
    Write-Info "已拒绝 $SftpGroup 组的本地/RDP 交互登录（只能走 SFTP）"
} catch {
    Write-Fail "配置'拒绝本地登录'失败：$($_.Exception.Message)`n请确认 secedit 可用（安全策略数据库未被锁定）后重跑"
}

# ---------------------------------------------------------------- 3. 安装 frpc
Write-Step 3 "安装 frpc v$FrpVersion"

$skipFrp = $false
if (Test-Path "$FrpDir\frpc.exe") {
    $cur = (& "$FrpDir\frpc.exe" --version 2>$null | Out-String).Trim()
    if ($cur -eq $FrpVersion) {
        Write-Info "frpc v$FrpVersion 已安装，跳过下载"
        $skipFrp = $true
    }
}
if (-not $skipFrp) {
    $zipName = "frp_$($FrpVersion)_windows_amd64.zip"
    $zipPath = Join-Path $env:TEMP $zipName
    $rel = "https://github.com/fatedier/frp/releases/download/v$FrpVersion"
    $zipSha = Get-FrpZipSha256 -Version $FrpVersion -ZipName $zipName -ReleaseUrl $rel
    # 仅在能校验 sha256 时才允许第三方镜像回退（防镜像投毒）
    $urls = @("$rel/$zipName")
    if ($zipSha) {
        $urls += @("https://gh-proxy.com/$rel/$zipName", "https://ghfast.top/$rel/$zipName")
    } else {
        Write-Warn2 "未能获取官方 sha256，已禁用镜像，仅从 GitHub 直连下载"
    }
    Invoke-Download -Urls $urls -OutFile $zipPath -Sha256 $zipSha
    $extractDir = Join-Path $env:TEMP "frp_$($FrpVersion)_windows_amd64"
    if (Test-Path $extractDir) { Remove-Item -Recurse -Force $extractDir }
    Expand-Archive -Path $zipPath -DestinationPath $env:TEMP -Force
    New-Item -ItemType Directory -Force -Path $FrpDir | Out-Null
    Copy-Item -Force -Path (Join-Path $extractDir 'frpc.exe') -Destination "$FrpDir\frpc.exe"
    Write-Info "frpc 已安装到 $FrpDir"
}

# 生成 frpc.toml（旧配置备份为 .bak）
$frpcTomlPath = Join-Path $FrpDir 'frpc.toml'
if (Test-Path $frpcTomlPath) { Copy-Item -Force $frpcTomlPath "$frpcTomlPath.bak" }
# 带宽限制行：设置了 SFTP_BANDWIDTH_LIMIT 才写入，否则留注释占位
$bwLine = if ($BandwidthLimit) { "transport.bandwidthLimit = `"$BandwidthLimit`"" }
          else { "# 未设置 SFTP_BANDWIDTH_LIMIT，不限速" }
$frpcToml = @"
# 由 setup-home-windows.ps1 于 $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') 自动生成

serverAddr = "$VpsIp"
serverPort = $FrpBindPort

auth.method = "token"
auth.token = "$FrpToken"

transport.tls.enable = true

# 隧道传输协议：tcp / kcp（KCP 走 UDP，需 VPS 侧 ufw 与云防火墙放行 UDP 同端口）
transport.protocol = "$FrpTransport"

# 登录失败不退出：VPS 重启或短暂宕机时在进程内持续重连，
# 不依赖 WinSW 的失败计数（其重试间隔最长要等 1 小时）
loginFailExit = false

transport.heartbeatInterval = 30
transport.heartbeatTimeout = 90

# 日志（TOML 单引号字符串，Windows 路径无需转义）。
# 注意必须写在 [[proxies]] 之前：TOML 中 [[proxies]] 之后的键值
# 都会归属到最后一个 proxy，写在其后会导致 frpc 报 unknown field "log"
log.to = '$FrpDir\frpc.log'
log.level = 'info'
log.maxDays = 7

# 把本机 sshd(22) 的 SFTP 服务映射到 VPS 的 remotePort 端口
[[proxies]]
name = "sftp"
type = "tcp"
localIP = "127.0.0.1"
localPort = 22
remotePort = $SftpPublicPort
# 单连接带宽上限（.env 的 SFTP_BANDWIDTH_LIMIT，如 5MB）
$bwLine
"@
Write-FileNoBom -Path $frpcTomlPath -Content $frpcToml
Write-Info "已生成 $frpcTomlPath"

$rc = Invoke-Native "$FrpDir\frpc.exe" @('verify', '-c', $frpcTomlPath)
if ($rc -ne 0) { Write-Fail "frpc.toml 校验失败，请检查 .env 与配置" }
Write-Info "frpc.toml 校验通过"

# ---------------------------------------------------------------- 4. 注册 Windows 服务（WinSW）
Write-Step 4 "用 WinSW 将 frpc 注册为 Windows 服务"

$winswExe = Join-Path $FrpDir 'frpc-service.exe'
if (-not (Test-Path $winswExe)) {
    $winswRel = "https://github.com/winsw/winsw/releases/download/v$WinSwVersion"
    # WinSW 官方不发布 checksums 文件；此哈希来自官方 GitHub 直连下载的 v2.12.0
    $winswSha = if ($WinSwVersion -eq '2.12.0') {
        '05b82d46ad331cc16bdc00de5c6332c1ef818df8ceefcd49c726553209b3a0da'
    } else { $null }
    $urls = @("$winswRel/WinSW-x64.exe")
    if ($winswSha) {
        $urls += @("https://gh-proxy.com/$winswRel/WinSW-x64.exe", "https://ghfast.top/$winswRel/WinSW-x64.exe")
    } else {
        Write-Warn2 "WinSW $WinSwVersion 未内置校验值，已禁用镜像，仅从 GitHub 直连下载"
    }
    Invoke-Download -Urls $urls -OutFile $winswExe -Sha256 $winswSha -MinBytes 500000
}
$winswXml = @"
<service>
  <id>frpc</id>
  <name>frp Client (frpc)</name>
  <description>frp 客户端：将本机 SFTP 通过公网 VPS 反代到外网（home-sftp-frp）</description>
  <executable>$FrpDir\frpc.exe</executable>
  <arguments>-c "$frpcTomlPath"</arguments>
  <startmode>Automatic</startmode>
  <onfailure action="restart" delay="10 sec"/>
  <onfailure action="restart" delay="30 sec"/>
  <onfailure action="none"/>
  <resetfailure>1 hour</resetfailure>
  <log mode="roll-by-size">
    <sizeThreshold>10240</sizeThreshold>
    <keepFiles>3</keepFiles>
  </log>
</service>
"@
Write-FileNoBom -Path "$FrpDir\frpc-service.xml" -Content $winswXml

if (Get-Service frpc -ErrorAction SilentlyContinue) {
    Write-Info "检测到已有 frpc 服务，重新注册..."
    Stop-Service frpc -Force -ErrorAction SilentlyContinue
    Invoke-Native $winswExe @('uninstall') | Out-Null
    Start-Sleep -Seconds 2
}
Invoke-Native $winswExe @('install') | Out-Null
Start-Service frpc
Start-Sleep -Seconds 3
Write-Info "frpc 服务已启动（开机自启，崩溃 10 秒后自动重启）"

# ---------------------------------------------------------------- 5. 电源与系统更新
Write-Step 5 "电源与系统更新（防服务静默中断）"

# 接通电源时禁止自动睡眠/休眠：睡眠会让 SFTP 与 frpc 一并失联，
# 是家庭端"莫名不通"的常见根因（仅关闭显示器不影响）
Invoke-Native 'powercfg.exe' @('/change', 'standby-timeout-ac', '0') | Out-Null
Invoke-Native 'powercfg.exe' @('/change', 'hibernate-timeout-ac', '0') | Out-Null
Write-Info "已设置：接通电源时永不睡眠/休眠"

if (Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue) {
    Write-Warn2 "本机带电池（笔记本）：以上仅调整'接通电源'策略，用电池时合盖/低电仍会睡眠，建议插电使用"
}
Write-Warn2 "建议在 设置 -> Windows 更新 -> 高级选项 -> 使用时段 设定活跃时段，避免自动重启打断大文件传输"

# ---------------------------------------------------------------- 6. 可选定时任务
Write-Step 6 "可选定时任务（保留期清理 / 上传通知，按 .env 配置）"

$taskDir     = 'C:\ProgramData\home-sftp-frp'
$cleanupTask = 'home-sftp-frp-cleanup'
$notifyTask  = 'home-sftp-frp-notify'

# 生成的任务脚本带 BOM 写出：任务以系统默认 PowerShell 运行，无 BOM 时中文注释会乱码
function Install-TaskScript {
    param([string]$Template, [hashtable]$Values, [string]$Dest)
    $tpl = Join-Path $PSScriptRoot $Template
    if (-not (Test-Path $tpl)) {
        Write-Fail "未找到模板 $Template（请把整个 windows/ 目录连同 .env 一起复制）"
    }
    $body = Get-Content -Raw -Encoding UTF8 $tpl
    foreach ($k in $Values.Keys) { $body = $body.Replace($k, $Values[$k]) }
    New-Item -ItemType Directory -Force -Path $taskDir | Out-Null
    # 任务目录收紧为 SYSTEM/管理员（脚本内含 webhook 地址等敏感值）
    $null = Invoke-Native 'icacls.exe' @($taskDir, '/inheritance:r', '/grant:r',
        '*S-1-5-18:F', '*S-1-5-32-544:F')
    [System.IO.File]::WriteAllText($Dest, $body, (New-Object System.Text.UTF8Encoding($true)))
}

# 6.1 保留期清理
$retentionDays = [int32]0
if ($RetentionRaw) {
    if (-not [int32]::TryParse($RetentionRaw, [ref]$retentionDays) -or $retentionDays -le 0) {
        Write-Fail "SFTP_RETENTION_DAYS 必须是正整数（天），当前：$RetentionRaw"
    }
}
if ($retentionDays -gt 0) {
    $dest = Join-Path $taskDir 'cleanup-uploads.ps1'
    Install-TaskScript -Template 'cleanup-uploads.ps1' `
        -Values @{ '__SFTP_ROOT__' = $SftpRoot; '__RETENTION_DAYS__' = "$retentionDays" } -Dest $dest
    $action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$dest`""
    $trigger = New-ScheduledTaskTrigger -Daily -At 03:30
    Register-ScheduledTask -TaskName $cleanupTask -Action $action -Trigger $trigger `
        -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
    Write-Info "已注册每天 03:30 清理任务：删除 $SftpRoot 下超过 $retentionDays 天的文件"
} elseif (Get-ScheduledTask -TaskName $cleanupTask -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $cleanupTask -Confirm:$false
    Write-Info "SFTP_RETENTION_DAYS 未配置，已移除旧清理任务"
}

# 6.2 上传通知
if ($WebhookUrl) {
    $dest = Join-Path $taskDir 'notify-upload.ps1'
    Install-TaskScript -Template 'notify-upload.ps1' `
        -Values @{ '__SFTP_ROOT__' = $SftpRoot; '__WEBHOOK_URL__' = $WebhookUrl } -Dest $dest
    $action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$dest`""
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) `
        -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
    Register-ScheduledTask -TaskName $notifyTask -Action $action -Trigger $trigger `
        -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
    Write-Info "已注册每 5 分钟上传通知任务（新文件到达 POST webhook）"
} elseif (Get-ScheduledTask -TaskName $notifyTask -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $notifyTask -Confirm:$false
    Write-Info "UPLOAD_NOTIFY_WEBHOOK 未配置，已移除旧通知任务"
}
if ($retentionDays -le 0 -and -not $WebhookUrl) {
    Write-Info "未配置 SFTP_RETENTION_DAYS / UPLOAD_NOTIFY_WEBHOOK，跳过定时任务"
}

# ---------------------------------------------------------------- 7. 状态检查与摘要
Write-Step 7 "状态检查"
Get-Service sshd, frpc | Format-Table Name, Status, StartType -AutoSize

Write-Info "frpc 日志最后 5 行（应出现 login to server success）："
if (Test-Path "$FrpDir\frpc.log") {
    Get-Content "$FrpDir\frpc.log" -Tail 5 | ForEach-Object { Write-Host "    $_" }
} else {
    Write-Warn2 "日志文件尚未生成，稍后可用：Get-Content '$FrpDir\frpc.log' -Tail 20"
}

Write-Host ""
Write-Host @"
============================================================
  家里 Windows 端配置完成
============================================================

  SFTP 数据根目录 : $SftpRoot
  frpc 配置/日志  : $FrpDir\frpc.toml  $FrpDir\frpc.log
  frpc 服务管理   : Get-Service frpc / Restart-Service frpc
  可选定时任务    : .env 配置 SFTP_USER_QUOTA_GB / SFTP_RETENTION_DAYS /
                    UPLOAD_NOTIFY_WEBHOOK 后重跑本脚本生效

  下一步（创建上传账号，可重复执行）：
      powershell -ExecutionPolicy Bypass -File .\add-sftp-user.ps1 -UserName zhangsan

  局域网内测试（同一 WiFi）：
      sftp -P 22 <用户名>@$(Get-LanIp)
  公网测试（创建账号后）：
      sftp -P $SftpPublicPort <用户名>@$VpsIp
"@ -ForegroundColor White
