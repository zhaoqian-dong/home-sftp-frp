<#
.SYNOPSIS
    删除一个 SFTP 上传账号：本地用户、NTFS 配额条目、sshd 配置块；数据目录可选删除

.DESCRIPTION
    对每个账号：
      - 删除 Windows 本地用户（自动移出所有组）
      - 清除该账号的 NTFS 配额条目（若启用了 SFTP_USER_QUOTA_GB）
      - 从 sshd_config 移除其 Match 配置块（先校验再落盘，与其他脚本同规范）并重启 sshd
      - 数据目录默认保留并打印路径；-DeleteData 或交互输入 yes 时才删除
    sftpusers 组本身保留（为空亦无害，重装时复用）。

    运行要求：管理员 PowerShell；与 .env 放同一目录。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\remove-sftp-user.ps1 -UserName zhangsan
    powershell -ExecutionPolicy Bypass -File .\remove-sftp-user.ps1 -UserName zhangsan -DeleteData
#>

param(
    [Parameter(Mandatory = $true, HelpMessage = '要删除的上传账号用户名')]
    [string]$UserName,
    [switch]$DeleteData,
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

# ---------------------------------------------------------------- 0. 前置检查
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Fail "请以管理员身份运行 PowerShell 后重试"
}

if ($UserName -notmatch '^[a-z][a-z0-9_]{2,31}$') {
    Write-Fail "用户名不合法：$UserName`n要求：小写字母开头，3-32 位，仅小写字母/数字/下划线"
}

$envMap    = Get-EnvMap -Path $EnvFile
$SftpRoot  = if ($envMap['SFTP_ROOT']) { $envMap['SFTP_ROOT'] } else { 'C:\SFTPData' }
$chrootDir = Join-Path $SftpRoot $UserName

# ---------------------------------------------------------------- 1. 本地用户
$existing = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
if ($existing) {
    try {
        Remove-LocalUser -Name $UserName -ErrorAction Stop
        Write-Info "已删除本地用户 $UserName"
    } catch {
        Write-Fail "删除用户失败（可能正在登录使用，请等其会话结束后重试）：$($_.Exception.Message)"
    }
} else {
    Write-Warn2 "本地用户 $UserName 不存在（可能已删除），继续清理其余项"
}

# ---------------------------------------------------------------- 2. NTFS 配额条目
if ($SftpRoot -match '^([A-Za-z]):\\') {
    $vol = "$($Matches[1]):"
    # 配额未启用或无条目时命令会失败，属正常情况，忽略即可
    $null = Invoke-Native 'fsutil.exe' @('quota', 'delete', $vol, $UserName)
}

# ---------------------------------------------------------------- 3. sshd 配置块（原子更新）
$beginMarker = "# >>> sftp-user:$UserName (managed by add-sftp-user.ps1) >>>"

$real = [System.IO.File]::ReadAllText($SshdConfig)
if ($real.Contains($beginMarker)) {
    $pattern = "(?s)\r?\n?# >>> sftp-user:$UserName \(managed by add-sftp-user\.ps1\) >>>.*?# <<< sftp-user:$UserName <<<\r?\n?"
    $candidate = [regex]::Replace($real, $pattern, '').TrimEnd() + "`r`n"

    $tmpCfg = Join-Path $env:TEMP 'sshd_config.candidate'
    Write-FileNoBom -Path $tmpCfg -Content $candidate

    $sshdExe = @("$env:SystemRoot\System32\OpenSSH\sshd.exe", 'C:\Program Files\OpenSSH\sshd.exe') |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $sshdExe) { Write-Fail "未找到 sshd.exe" }

    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $checkOutput = & $sshdExe -t -f $tmpCfg 2>&1 | ForEach-Object { "$_" }
    $ErrorActionPreference = $prev
    if ($LASTEXITCODE -ne 0) {
        Write-Host ($checkOutput -join "`n") -ForegroundColor Red
        Write-Fail "sshd 配置校验失败，未修改任何文件"
    }
    Write-FileNoBom -Path $SshdConfig -Content $candidate
    Restart-Service sshd
    Write-Info "已从 sshd_config 移除 $UserName 的配置块并重启 sshd"
} else {
    Write-Warn2 "sshd_config 中没有 $UserName 的配置块（可能从未创建或已清理）"
}

# ---------------------------------------------------------------- 4. 数据目录（默认保留）
if (Test-Path $chrootDir) {
    $delete = $false
    if ($DeleteData) {
        $delete = $true
    } else {
        $ans = Read-Host "删除该账号的全部数据 $chrootDir ？输入 yes 确认（直接回车保留）"
        $delete = ($ans -eq 'yes')
    }
    if ($delete) {
        try {
            Remove-Item -LiteralPath $chrootDir -Recurse -Force -ErrorAction Stop
            Write-Info "已删除数据目录 $chrootDir"
        } catch {
            Write-Warn2 "数据目录删除失败（文件可能被占用）：$($_.Exception.Message)"
            Write-Warn2 "稍后可手动删除：$chrootDir"
        }
    } else {
        Write-Info "数据目录已保留：$chrootDir（确认无用后可手动删除）"
    }
} else {
    Write-Info "数据目录不存在，跳过：$chrootDir"
}

# ---------------------------------------------------------------- 5. 摘要
Write-Host ""
Write-Host @"
============================================================
  账号 $UserName 已移除
------------------------------------------------------------
  查看剩余账号 ： .\list-sftp-users.ps1
  sftpusers 组 ： 已保留（为空时无害，重装可复用）
  OpenSSH 功能 ： 仍保留；所有上传账号删除后如不再需要，
                  可按 uninstall-home.ps1 的说明停用
============================================================
"@ -ForegroundColor Cyan
