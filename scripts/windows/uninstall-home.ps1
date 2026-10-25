<#
.SYNOPSIS
    家庭 Windows 端一键卸载：frpc 服务与程序、定时任务、sshd 停用；数据与账号可选清理

.DESCRIPTION
    默认行为（交互确认后执行）：
      - 停止并注销 frpc 服务（WinSW），删除 C:\Program Files\frp
      - 注销本项目的清理/通知定时任务，删除 C:\ProgramData\home-sftp-frp
      - 停用 sshd 并移除 22 端口防火墙规则（OpenSSH Server 功能保留，可按提示彻底移除）
      - SFTP 数据目录与上传账号默认保留（防止误删文件）

    -Force       跳过"是否继续"确认
    -DeleteData  连同数据目录、sftpusers 组内全部本地账号一起清除（不可恢复）

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\uninstall-home.ps1
    powershell -ExecutionPolicy Bypass -File .\uninstall-home.ps1 -Force
    powershell -ExecutionPolicy Bypass -File .\uninstall-home.ps1 -Force -DeleteData
#>

param(
    [switch]$Force,
    [switch]$DeleteData,
    [string]$EnvFile = (Join-Path $PSScriptRoot '.env')
)

$ErrorActionPreference = 'Stop'
$FrpDir    = 'C:\Program Files\frp'
$TaskDir   = 'C:\ProgramData\home-sftp-frp'
$SftpGroup = 'sftpusers'

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

# ---------------------------------------------------------------- 0. 前置检查
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Fail "请以管理员身份运行 PowerShell 后重试"
}

$envMap   = Get-EnvMap -Path $EnvFile
$SftpRoot = if ($envMap['SFTP_ROOT']) { $envMap['SFTP_ROOT'] } else { 'C:\SFTPData' }

if (-not $Force) {
    $ans = Read-Host "将移除 frpc 服务与程序、定时任务，并停用 sshd。继续？(y/N)"
    if ($ans -notmatch '^[yY]') { Write-Host "已取消"; exit 0 }
}

# ---------------------------------------------------------------- 1. frpc 服务与程序
Write-Info "[1/5] 移除 frpc 服务与程序..."
if (Get-Service frpc -ErrorAction SilentlyContinue) {
    Stop-Service frpc -Force -ErrorAction SilentlyContinue
}
$winswExe = Join-Path $FrpDir 'frpc-service.exe'
if (Test-Path $winswExe) {
    $null = Invoke-Native $winswExe @('uninstall')
} elseif (Get-Service frpc -ErrorAction SilentlyContinue) {
    # WinSW 不在但服务残留：直接删服务
    $null = Invoke-Native 'sc.exe' @('delete', 'frpc')
}
Start-Sleep -Seconds 2
if (Test-Path $FrpDir) {
    try {
        Remove-Item -LiteralPath $FrpDir -Recurse -Force -ErrorAction Stop
        Write-Info "已删除 $FrpDir"
    } catch {
        Write-Warn2 "$FrpDir 删除失败（文件可能被占用）：$($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------- 2. 定时任务
Write-Info "[2/5] 注销本项目定时任务..."
foreach ($t in @('home-sftp-frp-cleanup', 'home-sftp-frp-notify')) {
    if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue
        Write-Info "已注销任务 $t"
    }
}
if (Test-Path $TaskDir) {
    Remove-Item -LiteralPath $TaskDir -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- 3. sshd 停用
Write-Info "[3/5] 停用 sshd 与 22 端口防火墙规则..."
Stop-Service sshd -ErrorAction SilentlyContinue
Set-Service sshd -StartupType Disabled -ErrorAction SilentlyContinue
Remove-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
Write-Warn2 "sshd 已停用、22 端口规则已移除；OpenSSH Server 功能仍保留，如需彻底移除："
Write-Host "    Remove-WindowsCapability -Online -Name ((Get-WindowsCapability -Online -Name 'OpenSSH.Server*').Name)" -ForegroundColor White

# ---------------------------------------------------------------- 4. 数据与账号
Write-Info "[4/5] 清理数据目录与账号..."
$group   = Get-LocalGroup -Name $SftpGroup -ErrorAction SilentlyContinue
$members = @()
if ($group) {
    $members = @(Get-LocalGroupMember -Group $group -ErrorAction SilentlyContinue |
        ForEach-Object { ($_.Name -split '\\')[-1] })
}
if ($DeleteData) {
    foreach ($m in $members) {
        Remove-LocalUser -Name $m -ErrorAction SilentlyContinue
        Write-Info "已删除本地账号 $m"
    }
    if ($group) { Remove-LocalGroup -Name $SftpGroup -ErrorAction SilentlyContinue }
    if (Test-Path $SftpRoot) {
        try {
            Remove-Item -LiteralPath $SftpRoot -Recurse -Force -ErrorAction Stop
            Write-Info "已删除数据目录 $SftpRoot"
        } catch {
            Write-Warn2 "数据目录删除失败（文件可能被占用）：$($_.Exception.Message)"
        }
    }
} else {
    if ($members.Count -gt 0) {
        Write-Warn2 "以下本地账号已保留（用 -DeleteData 可一并清除）：$($members -join ', ')"
    }
    if (Test-Path $SftpRoot) {
        Write-Warn2 "SFTP 数据目录已保留：$SftpRoot（确认无用后手动删除）"
    }
    if ($group) { Write-Info "sftpusers 组已保留" }
}

# ---------------------------------------------------------------- 5. 摘要
Write-Info "[5/5] 完成"
Write-Host ""
Write-Host @"
============================================================
  家庭 Windows 端已卸载完成
------------------------------------------------------------
  已移除：frpc 服务与程序、本项目定时任务、sshd 开机自启（服务已停用）
  电源设置：接电永不睡眠的设置未回退（对日常使用无害，可在
            控制面板 -> 电源选项 中按需恢复）
  保留  ：OpenSSH Server 功能（已停用）、$SftpRoot 数据、上传账号（未加 -DeleteData 时）

  重新安装：重跑 setup-home-windows.ps1 即可
============================================================
"@ -ForegroundColor Cyan
