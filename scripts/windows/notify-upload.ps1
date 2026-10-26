<#
.SYNOPSIS
    （定时任务模板）轮询上传目录，新文件到达时 POST JSON 到 webhook

.DESCRIPTION
    由 setup-home-windows.ps1 生成到 C:\ProgramData\home-sftp-frp\ 并注册为
    SYSTEM 计划任务（每 5 分钟）。占位符 __SFTP_ROOT__ / __WEBHOOK_URL__ 在
    生成时被替换为 .env 的对应值；修改 .env 后重跑 setup-home-windows.ps1 即更新。

    状态存于同目录 notify-state.json（记录每个账号的"文件数:总字节"）。
    首次见到某账号只建立基线不通知，避免历史文件触发通知轰炸；
    仅当总字节数增长时推送（删除文件不打扰）。

    通知体为 UTF-8 JSON，含 title / desp 字段（Server酱 sctapi.ftqq.com/<KEY>.send
    可直接使用），并附带 user / new_bytes / total_files / total_bytes 供其他服务取用。
#>

$ErrorActionPreference = 'SilentlyContinue'
$root    = '__SFTP_ROOT__'
$webhook = '__WEBHOOK_URL__'
if (-not $webhook) { exit 0 }

$stateFile = Join-Path $PSScriptRoot 'notify-state.json'
$state = @{}
if (Test-Path $stateFile) {
    try {
        (Get-Content $stateFile -Raw | ConvertFrom-Json).PSObject.Properties |
            ForEach-Object { $state[$_.Name] = $_.Value }
    } catch { $state = @{} }   # 状态文件损坏时按全新基线重建（自愈）
}

$changed = $false
foreach ($dir in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
    $up = Join-Path $dir.FullName 'upload'
    if (-not (Test-Path $up)) { continue }

    $files = @(Get-ChildItem -LiteralPath $up -File -Recurse -ErrorAction SilentlyContinue)
    $totalBytes = [long]($files | Measure-Object Length -Sum).Sum
    if ($null -eq $totalBytes) { $totalBytes = 0 }
    $cur = '{0}:{1}' -f $files.Count, $totalBytes

    $prev = $state[$dir.Name]
    if ($prev -ne $cur) {
        # 严格校验旧状态格式（N:字节）；空/缺失/损坏都不匹配 → 视为基线重建。
        # 注意不能用 -as [long] 兜底：$null -as [long] 会得到 0 而非 $null
        $oldBytes = $null
        if ("$prev" -match '^\d+:(\d+)$') { $oldBytes = [long]$Matches[1] }
        if ($null -ne $oldBytes) {
            $newCount = [long](($cur -split ':')[0])
            $newBytes = [long](($cur -split ':')[1])
            if ($newBytes -gt $oldBytes) {
                $deltaMb  = [Math]::Round(($newBytes - $oldBytes) / 1MB, 1)
                $totalMb  = [Math]::Round($newBytes / 1MB, 1)
                $payload = @{
                    title       = '家庭 SFTP 收到新文件'
                    desp        = "账号 $($dir.Name)：新增 $deltaMb MB（现共 $newCount 个文件 / $totalMb MB）"
                    user        = $dir.Name
                    new_bytes   = $newBytes - $oldBytes
                    total_files = $newCount
                    total_bytes = $newBytes
                }
                # 5.1 的 Invoke-RestMethod 传字符串会按 ANSI 编码，中文需显式 UTF8 字节
                $json = [System.Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json))
                Invoke-RestMethod -Uri $webhook -Method Post `
                    -ContentType 'application/json; charset=utf-8' -Body $json -TimeoutSec 10 | Out-Null
            }
        }
        $state[$dir.Name] = $cur
        $changed = $true
    }
}

if ($changed) {
    $state | ConvertTo-Json | Set-Content -Path $stateFile -Encoding UTF8
}
