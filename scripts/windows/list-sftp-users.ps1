<#
.SYNOPSIS
    列出全部 SFTP 上传账号：本地用户状态、数据目录与磁盘占用、配额、配置一致性

.DESCRIPTION
    以 sshd_config 中的托管配置块（# >>> sftp-user:xxx <<< 标记）为准列出账号，
    并交叉核对：本地用户是否存在、数据目录/upload 是否存在、磁盘占用、
    NTFS 配额条目（若启用）、sftpusers 组里是否有游离成员（不在配置块中）。

    运行要求：管理员 PowerShell（读取 sshd_config 与各账号目录需要）。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\list-sftp-users.ps1
#>

param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '.env')
)

$ErrorActionPreference = 'Stop'
$SftpGroup  = 'sftpusers'
$SshdConfig = "$env:ProgramData\ssh\sshd_config"

# ---------------------------------------------------------------- 通用工具
function Write-Fail { param($m) Write-Host "[ERROR] $m" -ForegroundColor Red; exit 1 }

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

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    return '{0} KB' -f [Math]::Round($Bytes / 1KB)
}

# ---------------------------------------------------------------- 0. 前置检查
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Fail "请以管理员身份运行 PowerShell 后重试"
}

$envMap   = Get-EnvMap -Path $EnvFile
$SftpRoot = if ($envMap['SFTP_ROOT']) { $envMap['SFTP_ROOT'] } else { 'C:\SFTPData' }

# ---------------------------------------------------------------- 1. 收集账号
$real = [System.IO.File]::ReadAllText($SshdConfig)
$names = [regex]::Matches($real, '# >>> sftp-user:(\S+) \(managed by add-sftp-user\.ps1\) >>>') |
    ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique

# 配额条目查询（未启用配额时结果为空）
$quotaText = ''
if ($SftpRoot -match '^([A-Za-z]):\\') {
    $vol = "$($Matches[1]):"
    $quotaText = (& fsutil.exe quota query $vol 2>$null | Out-String)
}

$rows = @()
foreach ($name in $names) {
    $user   = Get-LocalUser -Name $name -ErrorAction SilentlyContinue
    $chroot = Join-Path $SftpRoot $name
    $upload = Join-Path $chroot 'upload'

    $sizeText = '-'
    $dirState = '正常'
    if (-not $user) { $dirState = '缺本地用户' }
    if (Test-Path $upload) {
        $sum = (Get-ChildItem -LiteralPath $upload -File -Recurse -ErrorAction SilentlyContinue |
            Measure-Object Length -Sum).Sum
        if ($null -eq $sum) { $sum = 0 }
        $sizeText = Format-Size ([long]$sum)
    } else {
        $sizeText = '目录缺失'
        if ($dirState -eq '正常') { $dirState = '缺 upload 目录' }
    }

    $quotaLine = ($quotaText -split "`n" | Where-Object { $_ -match [regex]::Escape($name) } |
        Select-Object -First 1)
    $quotaText2 = if ($quotaLine) { ($quotaLine.Trim() -replace '\s+', ' ') } else { '-' }

    $rows += [pscustomobject]@{
        账号       = $name
        本地用户   = if ($user) { if ($user.Enabled) { '启用' } else { '已禁用' } } else { '不存在' }
        磁盘占用   = $sizeText
        NTFS配额   = $quotaText2
        状态       = $dirState
    }
}

# sftpusers 组中的游离成员（有组身份但没有 sshd 配置块）
$group = Get-LocalGroup -Name $SftpGroup -ErrorAction SilentlyContinue
$orphans = @()
if ($group) {
    $orphans = @(Get-LocalGroupMember -Group $group -ErrorAction SilentlyContinue |
        ForEach-Object { ($_.Name -split '\\')[-1] } |
        Where-Object { $names -notcontains $_ })
}

# ---------------------------------------------------------------- 2. 输出
Write-Host ""
Write-Host "SFTP 上传账号（共 $($rows.Count) 个，数据根目录：$SftpRoot）"
Write-Host "============================================================"
if ($rows.Count -eq 0) {
    Write-Host "  （还没有账号，运行 add-sftp-user.ps1 创建）"
} else {
    $rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
}
if ($orphans.Count -gt 0) {
    Write-Host "[WARN] sftpusers 组中存在没有配置块的游离成员：$($orphans -join ', ')" -ForegroundColor Yellow
    Write-Host "       可用 add-sftp-user.ps1 重建，或手动 Remove-LocalUser 清理" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "常用操作："
Write-Host "  创建/重置密码  .\add-sftp-user.ps1 -UserName <名>"
Write-Host "  删除账号      .\remove-sftp-user.ps1 -UserName <名>（-DeleteData 连数据删）"
