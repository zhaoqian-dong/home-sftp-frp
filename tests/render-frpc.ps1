# CI 用：渲染 setup-home-windows.ps1 内嵌的 frpc.toml 模板到 /tmp/ci-artifacts/
# 使用与真实部署相同的可扩展字符串展开语义（$var 与 $(...)），产物供 frpc verify
# 与模板一致性校验使用
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$content = Get-Content -Raw (Join-Path $repoRoot 'scripts/windows/setup-home-windows.ps1')
$m = [regex]::Match($content, '(?s)\$frpcToml = @"\r?\n(.*?\r?\n)"@')
if (-not $m.Success) { throw '未找到 frpcToml here-string' }

$VpsIp          = '203.0.113.7'
$FrpBindPort    = '7000'
$FrpToken       = 'ci-test-token-0123456789abcdef'
$SftpPublicPort = '6022'
$FrpTransport   = 'tcp'
$FrpVersion     = '0.71.1'
$FrpDir         = 'C:\Program Files\frp'
$BandwidthLimit = ''
# 与 setup-home-windows.ps1 相同的 $bwLine 逻辑
$bwLine = if ($BandwidthLimit) { "transport.bandwidthLimit = `"$BandwidthLimit`"" }
          else { "# 未设置 SFTP_BANDWIDTH_LIMIT，不限速" }

$rendered = $ExecutionContext.InvokeCommand.ExpandString($m.Groups[1].Value)

$outDir = '/tmp/ci-artifacts'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
[System.IO.File]::WriteAllText((Join-Path $outDir 'frpc.toml'), $rendered,
    (New-Object System.Text.UTF8Encoding($false)))
"rendered -> $outDir/frpc.toml"
