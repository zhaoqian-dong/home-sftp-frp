<#
.SYNOPSIS
    Windows 客户端一键配置：安装 WinSCP 图形界面，并在桌面生成
    「连接 SFTP」快捷入口 + 命令行上传脚本 + 给上传者的说明文件

.DESCRIPTION
    1. 静默安装 WinSCP（优先 winget，失败回退官方安装包）
    2. 在桌面生成 Home-SFTP 文件夹：
         - 连接SFTP.cmd        双击即用 WinSCP 打开 SFTP 会话
         - upload.ps1          命令行上传：.\upload.ps1 -Path C:\data\xxx.zip
         - 上传者连接说明.txt   可直接发给对方的一页说明
    3. 账号密码默认取 .env 中的 SFTP_USER（先用 add-sftp-user.ps1 创建），
       也可用参数覆盖；密码以 URL 编码形式嵌入生成的文件

    运行要求：管理员 PowerShell（WinSCP 为机器级安装）；与 .env 放同一目录。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\setup-client.ps1
    powershell -ExecutionPolicy Bypass -File .\setup-client.ps1 -SftpUser zhangsan -SftpPassword 'Abc12345'
#>

param(
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


# ---------------------------------------------------------------- 通用工具
function Write-Info  { param($m) Write-Host "[INFO] $m" -ForegroundColor Green }
function Write-Warn2 { param($m) Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Write-Step  { param($n, $m) Write-Host "`n==> [$n/3] $m" -ForegroundColor Cyan }
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

function Invoke-Download {
    param([string[]]$Urls, [string]$OutFile, [int]$MinBytes = 1000000)
    foreach ($u in $Urls) {
        Write-Info "下载：$u"
        $rc = Invoke-Native 'curl.exe' @('-fsSL', '--connect-timeout', '10', '--retry', '2', '-o', $OutFile, $u)
        if ($rc -eq 0 -and (Test-Path $OutFile) -and ((Get-Item $OutFile).Length -ge $MinBytes)) { return }
        Write-Warn2 "下载失败，尝试下一个源..."
    }
    Write-Fail "所有下载源均失败，请手动安装 WinSCP（https://winscp.net）后重跑"
}

function Write-FileBom {
    param([string]$Path, [string]$Content)
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($true)))
}
function Write-FileNoBom {
    param([string]$Path, [string]$Content)
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

# ---------------------------------------------------------------- 0. 前置检查与参数
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Fail "请以管理员身份运行 PowerShell（WinSCP 需要机器级安装）后重试"
}

$envMap = Get-EnvMap -Path $EnvFile
$VpsIp          = $envMap['VPS_IP']
$SftpPublicPort = if ($envMap['SFTP_PUBLIC_PORT']) { $envMap['SFTP_PUBLIC_PORT'] } else { '6022' }
if (-not $VpsIp) { Write-Fail ".env 中 VPS_IP 为空，请先填写 VPS 公网 IP" }

if (-not $SftpUser) { $SftpUser = $envMap['SFTP_USER'] }
if (-not $SftpUser) { $SftpUser = Read-Host '请输入上传账号用户名（先在家里 Windows 用 add-sftp-user.ps1 创建）' }
if (-not $SftpPassword) {
    $sec = Read-Host "请输入 $SftpUser 的密码（输入不回显）" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { $SftpPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}
if (-not $SftpUser -or -not $SftpPassword) { Write-Fail "账号或密码为空" }

# 密码做 URL 编码，安全嵌入 WinSCP 会话 URL
$encUser = [uri]::EscapeDataString($SftpUser)
$encPass = [uri]::EscapeDataString($SftpPassword)

# ---------------------------------------------------------------- 1. 安装 WinSCP
Write-Step 1 "安装 WinSCP（图形界面 SFTP 客户端）"

function Find-WinScpCom {
    @('C:\Program Files (x86)\WinSCP\WinSCP.com', 'C:\Program Files\WinSCP\WinSCP.com') |
        Where-Object { Test-Path $_ } | Select-Object -First 1
}

$winscpCom = Find-WinScpCom
if (-not $winscpCom) {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Info "通过 winget 静默安装..."
        Invoke-Native 'winget' @('install', '--id', 'WinSCP.WinSCP', '-e', '--silent',
            '--accept-package-agreements', '--accept-source-agreements') | Out-Null
        $winscpCom = Find-WinScpCom
    } else {
        Write-Warn2 "未检测到 winget"
    }
}
if (-not $winscpCom) {
    Write-Info "回退：直接下载官方安装包静默安装..."
    $setup = Join-Path $env:TEMP 'WinSCP-Setup.exe'
    Invoke-Download -Urls @(
        'https://winscp.net/download/WinSCP-6.5.1-Setup.exe',
        'https://gh-proxy.com/https://winscp.net/download/WinSCP-6.5.1-Setup.exe',
        'https://winscp.net/download/WinSCP-6.3.7-Setup.exe',
        'https://gh-proxy.com/https://winscp.net/download/WinSCP-6.3.7-Setup.exe'
    ) -OutFile $setup
    Invoke-Native $setup @('/VERYSILENT', '/NORESTART') | Out-Null
    $winscpCom = Find-WinScpCom
}
if (-not $winscpCom) { Write-Fail "WinSCP 安装失败，请手动安装后重跑本脚本" }
$winscpExe = $winscpCom -replace '\.com$', '.exe'
Write-Info "WinSCP 已就绪：$winscpExe"

# ---------------------------------------------------------------- 2. 生成桌面文件
Write-Step 2 "生成桌面 Home-SFTP 工具集"

$desktop = [Environment]::GetFolderPath('Desktop')
$outDir  = Join-Path $desktop 'Home-SFTP'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

# 2.1 双击连接（注释用 ASCII，规避 cmd 代码页问题）
$connectCmd = @"
@echo off
rem Double-click to open WinSCP session for home SFTP.
rem NOTE: password is stored in plain text in this file - do not share it.
start "" "$winscpExe" "sftp://$encUser`:$encPass@$VpsIp`:$SftpPublicPort"
"@
Write-FileNoBom -Path (Join-Path $outDir '连接SFTP.cmd') -Content $connectCmd

# 2.2 命令行上传脚本（凭据已内置）
$uploadTemplate = @'
# 由 setup-client.ps1 自动生成 —— 命令行上传文件/目录到家庭 SFTP
# 用法：
#   .\upload.ps1 -Path C:\data\report.pdf
#   .\upload.ps1 -Path C:\data\photos            （目录整体上传）
# 提示：首次连接会提示接受主机指纹，输入 y 回车即可（只此一次）
# 弱网断线可直接重跑同一命令，已启用断点续传（-resume）
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [string]$RemoteDir = '/upload'
)
$SftpHost  = '__VPS_IP__'
$Port      = __PORT__
$User      = '__USER__'
$EncPass   = '__ENC_PASS__'
$WinscpCom = '__WINSCP_COM__'

$item = Get-Item -LiteralPath $Path
if (-not $item) { Write-Host "本地路径不存在：$Path" -ForegroundColor Red; exit 1 }

$putCmd = if ($item.PSIsContainer) { 'put -r -resume' } else { 'put -resume' }
Write-Host "上传 $($item.FullName) -> $RemoteDir ..."
& $WinscpCom /command `
    "open sftp://$($User):$EncPass@$($SftpHost):$Port/ -timeout=15" `
    "cd $RemoteDir" `
    "$putCmd `"$($item.FullName)`"" `
    "exit"
if ($LASTEXITCODE -ne 0) {
    Write-Host "上传失败（exit=$LASTEXITCODE）。若是首次使用，请先双击桌面 连接SFTP.cmd 接受一次主机指纹。" -ForegroundColor Red
    exit 1
}
Write-Host "上传完成" -ForegroundColor Green
'@
$uploadPs1 = $uploadTemplate.
    Replace('__VPS_IP__', $VpsIp).
    Replace('__PORT__', $SftpPublicPort).
    Replace('__USER__', $SftpUser).
    Replace('__ENC_PASS__', $encPass).
    Replace('__WINSCP_COM__', $winscpCom)
Write-FileBom -Path (Join-Path $outDir 'upload.ps1') -Content $uploadPs1

# 2.3 给上传者的一页说明
$guide = @"
家庭 SFTP 上传说明（可直接发给上传者）
============================================================

连接信息
------------------------------------------------------------
  地址 : $VpsIp
  端口 : $SftpPublicPort
  协议 : SFTP（SSH 文件传输，不是 FTP）
  用户 : $SftpUser
  密码 : $SftpPassword
  登录后直接位于自己的 /upload 目录，只能看到自己的文件

方式一：WinSCP（Windows 推荐）
------------------------------------------------------------
  1. 官网 https://winscp.net 下载安装（或直接用免安装绿色版）
  2. 新建会话，按上面四项填写；文件协议选 SFTP，点"登录"
  3. 首次连接弹出"未知主机密钥"提示，点"是"继续（仅首次）
  4. 左边本地、右边远程，拖拽即可上传

方式二：FileZilla
------------------------------------------------------------
  文件 -> 站点管理器 -> 新站点：
    协议选 SFTP - SSH File Transfer Protocol
    主机 $VpsIp，端口 $SftpPublicPort，登录类型：正常

方式三：命令行（Windows 10/11 自带）
------------------------------------------------------------
    sftp -P $SftpPublicPort $SftpUser@$VpsIp
    输入密码后用 put 文件名 上传，help 查看命令

注意事项
------------------------------------------------------------
  - 请勿把这份说明转发到公开群组
  - 上传大文件速度取决于上传方网络与服务器带宽
============================================================
"@
Write-FileBom -Path (Join-Path $outDir '上传者连接说明.txt') -Content $guide

Write-Info "已生成到 $outDir ："
Get-ChildItem $outDir | ForEach-Object { Write-Host "    $($_.Name)" }

# ---------------------------------------------------------------- 3. 完成
Write-Step 3 "完成"
Write-Info "双击桌面 Home-SFTP\连接SFTP.cmd 即可打开 SFTP（首次连接需接受一次主机指纹）"
Write-Info "命令行上传示例："
Write-Host "    .\upload.ps1 -Path C:\data\report.pdf" -ForegroundColor White
Write-Warn2 "生成的文件内含明文密码，请勿转发；给上传者发『上传者连接说明.txt』前请先改掉其中密码一栏"
Invoke-Native 'explorer.exe' @($outDir) | Out-Null
