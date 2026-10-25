<#
.SYNOPSIS
    家里 Windows 机器一键配置：SFTP 服务端（内置 OpenSSH Server）+ frpc 反向隧道客户端

.DESCRIPTION
    步骤：
      1. 安装/启用 Windows 内置 OpenSSH Server（sshd，提供 SFTP 服务）
      2. 收紧 sshd 防火墙规则为仅限局域网（公网访问一律走 frp 隧道）
      3. 创建 SFTP 数据根目录 + sftpusers 用户组，并做 NTFS ACL 加固
      4. 安装 frpc 到 C:\Program Files\frp 并生成 frpc.toml
      5. 用 WinSW 把 frpc 注册为 Windows 服务（开机自启、崩溃自动重启）

    运行要求：管理员 PowerShell；本脚本与 .env 放在同一目录。
    家里路由器无需任何端口映射（frpc 只发起出站连接）。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\setup-home-windows.ps1
#>

param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '.env')
)

$ErrorActionPreference = 'Stop'
$FrpVersion   = '0.71.1'   # frp 版本，升级时只改这里
$WinSwVersion = '2.12.0'   # WinSW（Windows 服务包装器）版本
$FrpDir       = 'C:\Program Files\frp'
$SshdConfig   = "$env:ProgramData\ssh\sshd_config"
$SftpGroup    = 'sftpusers'

# ---------------------------------------------------------------- 通用工具
function Write-Info  { param($m) Write-Host "[INFO] $m" -ForegroundColor Green }
function Write-Warn2 { param($m) Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Write-Step  { param($n, $m) Write-Host "`n==> [$n/5] $m" -ForegroundColor Cyan }
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

# 多源下载：GitHub 直连失败自动回退国内加速镜像（用系统自带 curl.exe）
function Invoke-Download {
    param([string[]]$Urls, [string]$OutFile, [int]$MinBytes = 100000)
    foreach ($u in $Urls) {
        Write-Info "下载：$u"
        $rc = Invoke-Native 'curl.exe' @('-fsSL', '--connect-timeout', '10', '--retry', '2', '-o', $OutFile, $u)
        if ($rc -eq 0 -and (Test-Path $OutFile) -and ((Get-Item $OutFile).Length -ge $MinBytes)) { return }
        Write-Warn2 "下载失败，尝试下一个源..."
    }
    Write-Fail "所有下载源均失败，请检查网络；也可手动下载后放到 $env:TEMP 再重跑"
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

if (-not $VpsIp)    { Write-Fail ".env 中 VPS_IP 为空，请先填写 VPS 公网 IP" }
if (-not $FrpToken) { Write-Fail ".env 中 FRP_TOKEN 为空，请先在 VPS 上运行 setup-vps.sh，把生成的 token 回填进 .env" }

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
        Invoke-Download -Urls @(
            'https://github.com/PowerShell/Win32-OpenSSH/releases/download/v9.5.0.0p1-Beta/OpenSSH-Win64.zip',
            'https://gh-proxy.com/https://github.com/PowerShell/Win32-OpenSSH/releases/download/v9.5.0.0p1-Beta/OpenSSH-Win64.zip'
        ) -OutFile $sshZip
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
    Invoke-Download -Urls @(
        "$rel/$zipName",
        "https://gh-proxy.com/$rel/$zipName",
        "https://ghfast.top/$rel/$zipName"
    ) -OutFile $zipPath
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
$frpcToml = @"
# 由 setup-home-windows.ps1 于 $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') 自动生成

serverAddr = "$VpsIp"
serverPort = $FrpBindPort

auth.method = "token"
auth.token = "$FrpToken"

transport.tls.enable = true

transport.heartbeatInterval = 30
transport.heartbeatTimeout = 90

[[proxies]]
name = "sftp"
type = "tcp"
localIP = "127.0.0.1"
localPort = 22
remotePort = $SftpPublicPort

log.to = '$FrpDir\frpc.log'
log.level = 'info'
log.maxDays = 7
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
    Invoke-Download -Urls @(
        "$winswRel/WinSW-x64.exe",
        "https://gh-proxy.com/$winswRel/WinSW-x64.exe",
        "https://ghfast.top/$winswRel/WinSW-x64.exe"
    ) -OutFile $winswExe -MinBytes 500000
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

# ---------------------------------------------------------------- 5. 状态检查与摘要
Write-Step 5 "状态检查"
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

  下一步（创建上传账号，可重复执行）：
      powershell -ExecutionPolicy Bypass -File .\add-sftp-user.ps1 -UserName zhangsan

  局域网内测试（同一 WiFi）：
      sftp -P 22 <用户名>@$(Get-LanIp)
  公网测试（创建账号后）：
      sftp -P $SftpPublicPort <用户名>@$VpsIp
"@ -ForegroundColor White
