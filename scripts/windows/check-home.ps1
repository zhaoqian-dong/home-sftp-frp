<#
.SYNOPSIS
    家庭 Windows 端一键自检：服务 / 防火墙 / 配置一致性 / 隧道连通 / 全链路探测

.DESCRIPTION
    对应 README 的部署自检清单，免凭据即可运行（无需管理员）：
      - sshd / frpc 服务状态与自启、frpc 版本与 .env 一致性
      - 22 端口监听、防火墙是否仍收紧为局域网
      - frpc.toml 与 .env 的协议/端口一致性
      - frpc ↔ VPS 控制通道连接（tcp 模式查 ESTABLISHED）
      - 全链路探测：从本机连 VPS:6022 抓 SSH banner（VPS→隧道→本机 sshd 全链路）
    可选 -UploadTest：用 WinSCP 以真实账号传一个测试文件再删除，做端到端验证。

    退出码：0 全部通过（可有 WARN）；1 存在 FAIL。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\check-home.ps1
    powershell -ExecutionPolicy Bypass -File .\check-home.ps1 -UploadTest
#>

param(
    [switch]$UploadTest,
    [string]$SftpUser,
    [string]$SftpPassword,
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

$FrpDir = 'C:\Program Files\frp'

# ---------------------------------------------------------------- 通用工具
$script:PassN = 0; $script:WarnN = 0; $script:FailN = 0
function Write-Ok    { param($m) Write-Host "[PASS] $m" -ForegroundColor Green;  $script:PassN++ }
function Write-Warn2 { param($m) Write-Host "[WARN] $m" -ForegroundColor Yellow; $script:WarnN++ }
function Write-Bad   { param($m) Write-Host "[FAIL] $m" -ForegroundColor Red;    $script:FailN++ }

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

function Get-EnvMap {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return @{} }
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

# 免凭据全链路探测：连 <host>:<port> 并读取 SSH banner
function Get-SshBanner {
    param([string]$TargetHost, [int]$Port, [int]$TimeoutMs = 5000)
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $ar = $c.BeginConnect($TargetHost, $Port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs)) { $c.Close(); return $null }
        $null = $c.EndConnect($ar)
        $s = $c.GetStream(); $s.ReadTimeout = $TimeoutMs
        $buf = New-Object byte[] 64
        $n = $s.Read($buf, 0, 64)
        $c.Close()
        if ($n -le 0) { return $null }
        return [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
    } catch { return $null }
}

# ---------------------------------------------------------------- 配置
$envMap = Get-EnvMap -Path $EnvFile
$VpsIp          = $envMap['VPS_IP']
$FrpBindPort    = if ($envMap['FRP_BIND_PORT'])    { $envMap['FRP_BIND_PORT'] }    else { '7000' }
$SftpPublicPort = if ($envMap['SFTP_PUBLIC_PORT']) { $envMap['SFTP_PUBLIC_PORT'] } else { '6022' }
$FrpVersion     = if ($envMap['FRP_VERSION'])      { $envMap['FRP_VERSION'] }      else { '0.71.1' }
$FrpTransport   = if ($envMap['FRP_TRANSPORT'])    { $envMap['FRP_TRANSPORT'] }    else { 'tcp' }
$SftpRoot       = if ($envMap['SFTP_ROOT'])        { $envMap['SFTP_ROOT'] }        else { 'C:\SFTPData' }

Write-Host ""
Write-Host "==> 家庭 Windows 端自检（VPS：${VpsIp}，SFTP 端口：${SftpPublicPort}）" -ForegroundColor Cyan

# ---------- 1. .env ----------
if (Test-Path $EnvFile) { Write-Ok ".env 存在" } else { Write-Bad ".env 不存在：$EnvFile" }
if ($VpsIp)    { Write-Ok "VPS_IP = $VpsIp" }     else { Write-Bad ".env 缺 VPS_IP" }
if ($envMap['FRP_TOKEN']) { Write-Ok "FRP_TOKEN 已配置" } else { Write-Bad ".env 缺 FRP_TOKEN" }

# ---------- 2. sshd ----------
$sshd = Get-Service sshd -ErrorAction SilentlyContinue
if     ($sshd -and $sshd.Status -eq 'Running')   { Write-Ok "sshd 服务运行中" }
elseif ($sshd)                                   { Write-Bad "sshd 未运行（状态：$($sshd.Status)）" }
else                                             { Write-Bad "未找到 sshd 服务（重跑 setup-home-windows.ps1）" }
if ($sshd -and $sshd.StartType -eq 'Automatic')  { Write-Ok "sshd 开机自启" }
elseif ($sshd)                                   { Write-Warn2 "sshd 非开机自启（当前：$($sshd.StartType)）" }

# ---------- 3. frpc 服务 ----------
$frpcSvc = Get-Service frpc -ErrorAction SilentlyContinue
if     ($frpcSvc -and $frpcSvc.Status -eq 'Running') { Write-Ok "frpc 服务运行中" }
elseif ($frpcSvc)                                    { Write-Bad "frpc 未运行（状态：$($frpcSvc.Status)）" }
else                                                 { Write-Bad "未找到 frpc 服务（重跑 setup-home-windows.ps1）" }
if ($frpcSvc -and $frpcSvc.StartType -eq 'Automatic') { Write-Ok "frpc 开机自启" }
elseif ($frpcSvc)                                     { Write-Warn2 "frpc 非开机自启（当前：$($frpcSvc.StartType)）" }

# ---------- 4. frpc 版本 ----------
$frpcExe = Join-Path $FrpDir 'frpc.exe'
if (Test-Path $frpcExe) {
    $ver = (& $frpcExe --version 2>$null | Out-String).Trim()
    if ($ver -eq $FrpVersion) { Write-Ok "frpc v$ver 与 .env 的 FRP_VERSION 一致" }
    else { Write-Warn2 "frpc 版本 $ver 与 .env 期望 $FrpVersion 不一致（重跑 setup-home-windows.ps1 升级）" }
} else {
    Write-Bad "未找到 $frpcExe"
}

# ---------- 5. 22 端口监听 ----------
$listen = Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue
if ($listen) { Write-Ok "本机 22 端口监听中" }
else         { Write-Bad "本机 22 端口未监听（sshd 异常）" }

# ---------- 6. 防火墙收紧 ----------
$rule = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
if (-not $rule) {
    Write-Warn2 "未找到 OpenSSH-Server-In-TCP 规则（若被第三方安全软件接管请人工确认 22 仅限局域网）"
} elseif (-not $rule.Enabled) {
    Write-Bad "22 端口防火墙规则被禁用"
} else {
    $addr = ($rule | Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue).RemoteAddress
    if ($addr -contains 'LocalSubnet') { Write-Ok "sshd 防火墙仅限局域网" }
    else { Write-Warn2 "防火墙规则未限制 LocalSubnet（当前：$($addr -join ', ')）——重跑 setup 脚本收紧" }
}

# ---------- 7. frpc.toml 一致性 ----------
$tomlPath = Join-Path $FrpDir 'frpc.toml'
if (Test-Path $tomlPath) {
    Write-Ok "frpc.toml 存在"
    $raw = Get-Content -Path $tomlPath -Raw
    $mp = [regex]::Match($raw, 'transport\.protocol\s*=\s*"([^"]+)"')
    if ($mp.Success -and $mp.Groups[1].Value -eq $FrpTransport) {
        Write-Ok "传输协议一致（$FrpTransport）"
    } elseif ($mp.Success) {
        Write-Warn2 "frpc.toml 协议为 $($mp.Groups[1].Value)，.env 为 $FrpTransport —— 重跑 setup 脚本同步"
    } else {
        Write-Warn2 "frpc.toml 未找到 transport.protocol（旧版配置，建议重跑 setup 脚本）"
    }
    $mr = [regex]::Match($raw, 'remotePort\s*=\s*(\d+)')
    if ($mr.Success -and $mr.Groups[1].Value -ne $SftpPublicPort) {
        Write-Warn2 "frpc.toml remotePort=$($mr.Groups[1].Value) 与 .env 的 $SftpPublicPort 不一致"
    }
} else {
    Write-Bad "frpc.toml 不存在：$tomlPath"
}

# ---------- 8. 控制通道连接 ----------
if ($FrpTransport -eq 'kcp') {
    Write-Host "[INFO] kcp 模式走 UDP，跳过 TCP 控制连接检查（以第 9 项全链路探测为准）" -ForegroundColor Green
} else {
    $est = Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
        Where-Object { $_.RemotePort -eq [int]$FrpBindPort }
    if ($est) { Write-Ok "frpc ↔ VPS 控制通道已建立（$(@($est).Count) 条连接）" }
    else      { Write-Bad "没有到 VPS:${FrpBindPort} 的连接 —— 隧道未连上（看 $FrpDir\frpc.log）" }
}

# ---------- 9. 数据目录 ----------
if (Test-Path $SftpRoot) {
    $ups = @(Get-ChildItem -LiteralPath $SftpRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName 'upload') })
    if ($ups.Count -gt 0) { Write-Ok "SFTP 根目录就绪，已有 $($ups.Count) 个账号目录" }
    else                  { Write-Warn2 "SFTP 根目录存在但还没有账号目录（运行 add-sftp-user.ps1）" }
} else {
    Write-Bad "SFTP 根目录不存在：$SftpRoot"
}

# ---------- 10. 电源设置 ----------
try {
    # SUB_SLEEP / STANDBYIDLE：Current AC Power Setting Index 为 0 表示接电永不睡眠
    $q = & powercfg /q SCHEME_CURRENT 238c9fa8-0aad-41ed-83f4-97be242c8f20 29f6c1db-86da-48c5-9ebf-c2ad5a80cd76 2>$null
    $line = $q | Select-String 'Current AC Power Setting Index'
    if ($line) {
        $idx = [Convert]::ToInt64((("$line" -split '0x')[-1]).Trim(), 16)
        if ($idx -eq 0) { Write-Ok "接通电源时永不睡眠/休眠" }
        else            { Write-Warn2 "接通电源仍会自动睡眠（重跑 setup-home-windows.ps1）" }
    } else {
        Write-Host "[INFO] 电源设置解析失败，跳过该项" -ForegroundColor Green
    }
} catch {
    Write-Host "[INFO] 电源设置检查跳过：$($_.Exception.Message)" -ForegroundColor Green
}

# ---------- 11. 全链路探测（免凭据） ----------
if ($VpsIp) {
    $banner = Get-SshBanner -TargetHost $VpsIp -Port ([int]$SftpPublicPort)
    if ($banner -like 'SSH-*') {
        Write-Ok "全链路通：本机 → VPS:${SftpPublicPort} → 隧道 → 本机 sshd（$($banner.Trim()))"
    } else {
        Write-Bad "全链路不通：连接 VPS:${SftpPublicPort} 未拿到 SSH banner（对照上面 frpc/服务各项，及 VPS 侧 check-vps.sh）"
    }
}

# ---------- 12. 可选端到端上传测试 ----------
if ($UploadTest) {
    Write-Host ""
    Write-Host "==> 端到端上传测试（真实账号传一个测试文件并删除）" -ForegroundColor Cyan
    if (-not $SftpUser)    { $SftpUser = Read-Host '上传账号用户名' }
    if (-not $SftpPassword) {
        $sec = Read-Host "请输入 $SftpUser 的密码（输入不回显）" -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { $SftpPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    $winscpCom = @('C:\Program Files (x86)\WinSCP\WinSCP.com', 'C:\Program Files\WinSCP\WinSCP.com') |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $winscpCom) { $winscpCom = (Get-Command winscp.com -ErrorAction SilentlyContinue).Source }
    if (-not $winscpCom) {
        Write-Warn2 "未找到 WinSCP，跳过上传测试（可先运行 setup-client.ps1）"
    } else {
        $tmpName = "sftp-e2e-{0}.txt" -f [guid]::NewGuid().ToString('N').Substring(0, 8)
        $tmp = Join-Path $env:TEMP $tmpName
        Set-Content -Path $tmp -Value ("home-sftp-frp e2e test " + (Get-Date -Format s))
        $encU = [uri]::EscapeDataString($SftpUser)
        $encP = [uri]::EscapeDataString($SftpPassword)
        # -hostkey=* 仅用于自检脚本临时接受指纹；日常客户端请按提示确认
        $rc = Invoke-Native $winscpCom @('/command',
            "open sftp://$encU`:$encP@$VpsIp`:$SftpPublicPort/ -hostkey=* -timeout=15",
            "put `"$tmp`" /upload/",
            "rm /upload/$tmpName",
            'exit')
        if ($rc -eq 0) { Write-Ok "端到端上传+删除测试通过（$SftpUser@${VpsIp}）" }
        else           { Write-Bad "端到端上传失败（exit=$rc）：检查账号是否存在/密码是否正确" }
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

# ---------- 摘要 ----------
Write-Host ""
Write-Host "自检完成：$($script:PassN) 通过 / $($script:WarnN) 警告 / $($script:FailN) 失败" -ForegroundColor Cyan
if ($script:FailN -gt 0) { exit 1 }
exit 0
