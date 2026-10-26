<#
.SYNOPSIS
    命令行上传文件/目录到家庭 SFTP（基于 WinSCP CLI）

.DESCRIPTION
    读取同目录 .env 的 VPS_IP / SFTP_PUBLIC_PORT / SFTP_USER；
    密码不落盘，未传参时交互式输入（不回显）。
    若想免输密码，建议用 setup-client.ps1 在桌面生成的
    upload.ps1（凭据内置版）。

.EXAMPLE
    .\upload.ps1 -Path C:\data\report.pdf
    .\upload.ps1 -Path C:\data\photos
    .\upload.ps1 -Path .\backup.zip -UserName zhangsan
#>

param(
    [Parameter(Mandatory = $true, HelpMessage = '要上传的本地文件或目录')]
    [string]$Path,
    [string]$RemoteDir = '/upload',
    [string]$UserName,
    [string]$Password,
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


function Write-Fail { param($m) Write-Host "[ERROR] $m" -ForegroundColor Red; exit 1 }

function Get-EnvMap {
    param([string]$Path2)
    if (-not (Test-Path $Path2)) { Write-Fail "未找到 .env：$Path2`n请把它与脚本放在同一目录" }
    $map = @{}
    foreach ($line in (Get-Content -Path $Path2 -Encoding UTF8)) {
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

# ---------------------------------------------------------------- 参数
$envMap = Get-EnvMap -Path $EnvFile
$VpsIp = $envMap['VPS_IP']
$Port  = if ($envMap['SFTP_PUBLIC_PORT']) { $envMap['SFTP_PUBLIC_PORT'] } else { '6022' }
if (-not $UserName) { $UserName = $envMap['SFTP_USER'] }
if (-not $VpsIp)   { Write-Fail ".env 中 VPS_IP 为空" }
if (-not $UserName) { Write-Fail "未指定账号：请传 -UserName 或在 .env 填 SFTP_USER" }

if (-not $Password) {
    $sec = Read-Host "请输入 $UserName 的密码（输入不回显）" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { $Password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

$item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
if (-not $item) { Write-Fail "本地路径不存在：$Path" }

# 查找 WinSCP CLI（setup-client.ps1 安装后位于以下常见位置）
$winscpCom = @('C:\Program Files (x86)\WinSCP\WinSCP.com', 'C:\Program Files\WinSCP\WinSCP.com') |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $winscpCom) {
    $found = (Get-Command winscp.com -ErrorAction SilentlyContinue).Source
    if ($found) { $winscpCom = $found }
}
if (-not $winscpCom) { Write-Fail "未找到 WinSCP，请先运行 setup-client.ps1 或从 https://winscp.net 安装" }

# ---------------------------------------------------------------- 上传
# -resume：断点续传，弱网中断后重跑同一命令可从上次进度继续
$encUser = [uri]::EscapeDataString($UserName)
$encPass = [uri]::EscapeDataString($Password)
$putCmd  = if ($item.PSIsContainer) { 'put -r -resume' } else { 'put -resume' }

Write-Host "上传 $($item.FullName) -> $RemoteDir （$VpsIp`:$Port）"
Write-Host "提示：首次连接会提示接受主机指纹，输入 y 回车即可（只此一次）"

& $winscpCom /command `
    "open sftp://$($encUser):$encPass@$($VpsIp):$Port/ -timeout=15" `
    "cd $RemoteDir" `
    "$putCmd `"$($item.FullName)`"" `
    "exit"

if ($LASTEXITCODE -ne 0) {
    Write-Host "上传失败（exit=$LASTEXITCODE）" -ForegroundColor Red
    exit 1
}
Write-Host "上传完成" -ForegroundColor Green
