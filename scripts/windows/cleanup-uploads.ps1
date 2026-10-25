<#
.SYNOPSIS
    （定时任务模板）删除上传目录中超过保留期的文件

.DESCRIPTION
    由 setup-home-windows.ps1 生成到 C:\ProgramData\home-sftp-frp\ 并注册为
    SYSTEM 计划任务（每天 03:30）。占位符 __SFTP_ROOT__ / __RETENTION_DAYS__
    在生成时被替换为 .env 的对应值；修改 .env 后重跑 setup-home-windows.ps1 即更新。
    只删除文件、保留目录结构；清理动作不可恢复，请谨慎设置天数。
#>

$ErrorActionPreference = 'SilentlyContinue'
$root = '__SFTP_ROOT__'
$days = __RETENTION_DAYS__
if ($days -le 0) { exit 0 }

$cutoff = (Get-Date).AddDays(-$days)
$log    = Join-Path $PSScriptRoot 'cleanup.log'

foreach ($dir in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
    $up = Join-Path $dir.FullName 'upload'
    if (-not (Test-Path $up)) { continue }
    $old = @(Get-ChildItem -LiteralPath $up -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff })
    if ($old.Count -gt 0) {
        $size = [long]($old | Measure-Object Length -Sum).Sum
        $old | Remove-Item -Force -ErrorAction SilentlyContinue
        Add-Content -Path $log -Encoding UTF8 -Value (
            "{0} 账号 {1}：清理 {2} 个文件 / {3} MB" -f (Get-Date -Format 'yyyy-MM-dd HH:mm'),
            $dir.Name, $old.Count, [Math]::Round($size / 1MB, 1))
    }
}
