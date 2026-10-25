<#
.SYNOPSIS
    新增/重置一个 SFTP 上传账号（可反复执行，每账号一条）

.DESCRIPTION
    对每个账号：
      - 创建 Windows 本地用户（加入 sftpusers 组，非管理员，密码永不过期）
      - 创建独立数据目录 <SFTP_ROOT>\<用户名>\upload，NTFS ACL 断继承，
        只有该用户（和 SYSTEM/管理员）能访问 —— 各账号之间完全隔离
      - 在 sshd_config 追加 per-user 配置块：
            Match User <用户名>
                ChrootDirectory <SFTP_ROOT>\<用户名>     # 登录后根目录锁在其数据目录
                ForceCommand internal-sftp -d /upload    # 只允许 SFTP，直接进入 upload
                禁端口转发 / X11 / TTY
        写入前先在临时文件上通过 sshd -t 校验，失败则不落盘，避免 sshd 起不来
      - 打印该账号的连接信息（发给上传者即可）

    运行要求：管理员 PowerShell；与 .env 放同一目录。
    Windows 说明：ChrootDirectory 需 OpenSSH >= 7.7（Win10 1809+ 内置版均满足）。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\add-sftp-user.ps1 -UserName zhangsan
    powershell -ExecutionPolicy Bypass -File .\add-sftp-user.ps1 -UserName zhangsan -Password 'Abc12345'
#>

param(
    [Parameter(Mandatory = $true, HelpMessage = '上传账号用户名（小写字母开头，3-32位小写字母/数字/下划线）')]
    [string]$UserName,
    [string]$Password,
    [string]$EnvFile = (Join-Path $PSScriptRoot '.env')
)

$ErrorActionPreference = 'Stop'
$SftpGroup  = 'sftpusers'
$SshdConfig = "$env:ProgramData\ssh\sshd_config"

# ---------------------------------------------------------------- 通用工具
function Write-Info  { param($m) Write-Host "[INFO] $m" -ForegroundColor Green }
function Write-Warn2 { param($m) Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Write-Fail  { param($m) Write-Host "[ERROR] $m" -ForegroundColor Red; exit 1 }

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
    if (-not (Test-Path $Path)) { Write-Fail "未找到 .env：$Path`n请把它与脚本放在同一目录" }
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

function Write-FileNoBom {
    param([string]$Path, [string]$Content)
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-LanIp {
    $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } |
        Select-Object -First 1
    if ($ip) { $ip.IPAddress } else { '<本机局域网IP>' }
}

# 生成 16 位字母数字随机密码（无易混淆字符；URL/脚本/图形界面里都无需转义）
function New-RandomPassword {
    $chars = 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'.ToCharArray()
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = New-Object byte[] 16
    $rng.GetBytes($bytes)
    -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
}

# ---------------------------------------------------------------- 0. 前置检查
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Fail "请以管理员身份运行 PowerShell 后重试"
}

# 用户名严格校验：只允许小写字母/数字/下划线，保证能安全拼进 sshd_config 正则
if ($UserName -notmatch '^[a-z][a-z0-9_]{2,31}$') {
    Write-Fail "用户名不合法：$UserName`n要求：小写字母开头，3-32 位，仅小写字母/数字/下划线（如 zhangsan）"
}
$reserved = @('administrator', 'admin', 'sshd', 'root', 'guest', 'defaultaccount', 'defaultuser0')
if ($reserved -contains $UserName) {
    Write-Fail "用户名 $UserName 是系统保留名，请换一个"
}

$envMap = Get-EnvMap -Path $EnvFile
$VpsIp          = $envMap['VPS_IP']
$SftpPublicPort = if ($envMap['SFTP_PUBLIC_PORT']) { $envMap['SFTP_PUBLIC_PORT'] } else { '6022' }
$SftpRoot       = if ($envMap['SFTP_ROOT'])        { $envMap['SFTP_ROOT'] }        else { 'C:\SFTPData' }
if (-not $VpsIp) { Write-Fail ".env 中 VPS_IP 为空，请先填写 VPS 公网 IP" }

$chrootDir = Join-Path $SftpRoot $UserName
$uploadDir = Join-Path $chrootDir 'upload'

# ---------------------------------------------------------------- 1. 用户与组
Write-Info "配置用户 $UserName ..."

if (-not (Get-LocalGroup -Name $SftpGroup -ErrorAction SilentlyContinue)) {
    New-LocalGroup -Name $SftpGroup -Description 'SFTP upload users (home-sftp-frp)' | Out-Null
}

$existing = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
if (-not $Password) { $Password = New-RandomPassword }
$secure = ConvertTo-SecureString $Password -AsPlainText -Force

if ($existing) {
    Write-Info "用户 $UserName 已存在，重置密码与属性"
    Set-LocalUser -Name $UserName -Password $secure
    Set-LocalUser -Name $UserName -PasswordNeverExpires $true
    Set-LocalUser -Name $UserName -UserMayNotChangePassword $true
    Set-LocalUser -Name $UserName -Description 'SFTP upload user (home-sftp-frp)'
} else {
    New-LocalUser -Name $UserName -Password $secure `
        -PasswordNeverExpires -UserMayNotChangePassword -AccountNeverExpires `
        -Description 'SFTP upload user (home-sftp-frp)' | Out-Null
    Write-Info "已创建用户 $UserName"
}

Add-LocalGroupMember -Group $SftpGroup -Member $UserName -ErrorAction SilentlyContinue

# 确保不在管理员组（安全兜底）
try {
    $adminGroup = Get-LocalGroup -Sid ([Security.Principal.SecurityIdentifier]'S-1-5-32-544')
    foreach ($m in (Get-LocalGroupMember -Group $adminGroup -ErrorAction SilentlyContinue)) {
        if ($m.Name -eq $UserName -or $m.Name -like "*\$UserName") {
            Remove-LocalGroupMember -Group $adminGroup -Member $m.Name
            Write-Warn2 "已将 $UserName 移出管理员组"
        }
    }
} catch { }

# ---------------------------------------------------------------- 2. 目录与 NTFS ACL
New-Item -ItemType Directory -Force -Path $uploadDir | Out-Null

foreach ($dir in @($chrootDir, $uploadDir)) {
    $icaclsArgs = @($dir, '/inheritance:r', '/grant:r',
        '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F', "${UserName}:(OI)(CI)M")
    if ((Invoke-Native 'icacls.exe' $icaclsArgs) -ne 0) { Write-Fail "icacls 设置 ACL 失败：$dir" }
}
# 根目录：仅 SYSTEM/管理员完全控制，sftpusers 组可读（不向下继承）
$rootArgs = @($SftpRoot, '/inheritance:r', '/grant:r',
    '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F', "${SftpGroup}:RX")
Invoke-Native 'icacls.exe' $rootArgs | Out-Null
Write-Info "数据目录已就绪并完成 ACL 加固：$chrootDir"

# ---------------------------------------------------------------- 3. sshd 配置（原子更新）
$beginMarker = "# >>> sftp-user:$UserName (managed by add-sftp-user.ps1) >>>"
$endMarker   = "# <<< sftp-user:$UserName <<<"

$real    = [System.IO.File]::ReadAllText($SshdConfig)
# 移除旧块（重置场景），再追加新块
$pattern = "(?s)\r?\n?# >>> sftp-user:$UserName \(managed by add-sftp-user\.ps1\) >>>.*?# <<< sftp-user:$UserName <<<\r?\n?"
$cleaned = [regex]::Replace($real, $pattern, '')

$block = @"
$beginMarker
Match User $UserName
    ChrootDirectory $chrootDir
    ForceCommand internal-sftp -d /upload
    AllowTcpForwarding no
    AllowAgentForwarding no
    X11Forwarding no
    PermitTunnel no
    PermitTTY no
$endMarker
"@
$candidate = $cleaned.TrimEnd() + "`r`n`r`n" + $block + "`r`n"

# 先在临时副本上校验，通过后才落盘，保证 sshd 不会因坏配置起不来
$tmpCfg = Join-Path $env:TEMP 'sshd_config.candidate'
Write-FileNoBom -Path $tmpCfg -Content $candidate

$sshdExe = @("$env:SystemRoot\System32\OpenSSH\sshd.exe", 'C:\Program Files\OpenSSH\sshd.exe') |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $sshdExe) { Write-Fail "未找到 sshd.exe，请先运行 setup-home-windows.ps1" }

$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
$checkOutput = & $sshdExe -t -f $tmpCfg 2>&1 | ForEach-Object { "$_" }
$ErrorActionPreference = $prev
if ($LASTEXITCODE -ne 0) {
    Write-Host ($checkOutput -join "`n") -ForegroundColor Red
    Write-Fail "sshd 配置校验失败，未修改任何文件"
}
Write-FileNoBom -Path $SshdConfig -Content $candidate
Restart-Service sshd
Write-Info "sshd 配置已更新并重启"

# ---------------------------------------------------------------- 4. 打印连接信息
Write-Host ""
Write-Host @"
============================================================
  SFTP 上传账号创建成功
------------------------------------------------------------
  地址（公网，走 VPS）: sftp://$VpsIp`:$SftpPublicPort
  地址（局域网直连）  : sftp://$(Get-LanIp):22
  用户名              : $UserName
  密码                : $Password
  登录后所在目录      : /upload（chroot 隔离，看不到其他目录）
------------------------------------------------------------
  请通过安全渠道（而非群聊明文）把以上信息发给上传者。
  上传者使用任意 SFTP 客户端即可：WinSCP / FileZilla / 命令行
      sftp -P $SftpPublicPort $UserName@$VpsIp
============================================================
"@ -ForegroundColor Cyan
Write-Warn2 "如密码含特殊字符，请提醒上传者在 WinSCP 里直接填入（不要拼 URL）"
