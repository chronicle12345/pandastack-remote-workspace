[CmdletBinding()]
param(
    [string]$EnvFile = '',
    [string]$AppId = '',
    [switch]$DryRun,
    [switch]$SkipVerify,
    [switch]$VerifyOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http

if ([string]::IsNullOrWhiteSpace($EnvFile)) {
    $EnvFile = Join-Path $PSScriptRoot '.env'
}
$EnvFile = [IO.Path]::GetFullPath($EnvFile)
$script:ApiKey = ''
$script:ApiBase = 'https://api.pandastack.ai/v1'

function Write-Step {
    param([string]$Message)
    Write-Host ('==> ' + $Message)
}

function Format-DisplayPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    try {
        $full = [IO.Path]::GetFullPath($Path)
        $root = [IO.Path]::GetFullPath($PSScriptRoot)
        if ($full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
            $relative = $full.Substring($root.Length).TrimStart([char[]]@('\', '/'))
            if ([string]::IsNullOrEmpty($relative)) { return '.' }
            return '.\' + $relative
        }
        $userHome = [Environment]::GetFolderPath('UserProfile')
        if (-not [string]::IsNullOrWhiteSpace($userHome) -and $full.StartsWith($userHome, [StringComparison]::OrdinalIgnoreCase)) {
            return '%USERPROFILE%' + $full.Substring($userHome.Length)
        }
        return $full
    } catch {
        return $Path
    }
}

function Normalize-PublicBaseUrl {
    param([string]$Value, [string]$Source = 'PDS_PUBLIC_URL')
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "$Source 不能为空。"
    }
    if ($Value -match '\s' -or $Value.Contains('?') -or $Value.Contains('#') -or $Value -match '^https://[^/?#]*@' -or $Value -match '^https://[^/?#]+:(?:/|$)') {
        throw "$Source 必须是 HTTPS 源地址，不能包含空白、账号信息、路径、查询参数或片段。"
    }
    try {
        $uri = [Uri]::new($Value)
        $port = $uri.Port
    } catch {
        throw "$Source 不是有效的 HTTPS 地址。"
    }
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https' -or [string]::IsNullOrWhiteSpace($uri.Host) -or $uri.UserInfo -or $uri.AbsolutePath -notin @('', '/') -or $uri.Query -or $uri.Fragment -or $port -lt 1 -or $port -gt 65535) {
        throw "$Source 必须是 HTTPS 源地址，不能包含账号信息、路径、查询参数或片段。"
    }
    return $uri.GetLeftPart([UriPartial]::Authority)
}

function Get-AppPublicBaseUrl {
    param([object]$App, [string]$Fallback)
    $value = ''
    if ($null -ne $App) {
        $property = $App.PSObject.Properties['url']
        if ($null -ne $property) { $value = [string]$property.Value }
    }
    if (-not [string]::IsNullOrWhiteSpace($value)) {
        return Normalize-PublicBaseUrl -Value $value -Source 'PandaStack 返回的 url'
    }
    if (-not [string]::IsNullOrWhiteSpace($Fallback)) {
        return Normalize-PublicBaseUrl -Value $Fallback -Source 'PDS_PUBLIC_URL'
    }
    throw 'PandaStack 没有返回 App 地址，且 PDS_PUBLIC_URL 为空。'
}
function Write-DeploymentSummary {
    param(
        [string]$AppId,
        [string]$AppName,
        [object]$App,
        [string]$DeployId,
        [string]$DeployStatus,
        [int]$Port,
        [int]$IdleSeconds,
        [int]$SessionTtlMinutes = 180
    )
    $configuredUrl = Get-Config 'PDS_PUBLIC_URL'
    $fallbackUrl = if (-not [string]::IsNullOrWhiteSpace($configuredUrl)) { $configuredUrl } else { "https://$AppId.pandastack.ai" }
    $publicBaseUrl = Get-AppPublicBaseUrl -App $App -Fallback $fallbackUrl
    $loginUrl = "$publicBaseUrl/login"
    $appStatus = ''
    if ($null -ne $App) {
        $statusProperty = $App.PSObject.Properties['status']
        if ($null -ne $statusProperty) { $appStatus = [string]$statusProperty.Value }
    }
    $report = [ordered]@{
        generated_at = (Get-Date).ToUniversalTime().ToString('o')
        app_id = $AppId
        app_name = $AppName
        public_domain = $publicBaseUrl
        login_url = $loginUrl
        deploy_id = $DeployId
        deploy_status = $DeployStatus
        app_status = $appStatus
        port = $Port
        idle_timeout_seconds = $IdleSeconds
        session_ttl_minutes = $SessionTtlMinutes
        web_username = 'browser'
        web_password_location = 'local .env: BROWSER_PASSWORD'
        root_password_location = 'local .env: ROOT_PASSWORD'
        ssh_script = 'connect-ssh.ps1'
    }
    $reportPath = Join-Path $PSScriptRoot 'deployment-report.json'
    [IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ''
    Write-Host 'PandaStack 部署信息'
    Write-Host ('  App ID：' + $AppId)
    Write-Host ('  App 名称：' + $AppName)
    Write-Host ('  公网地址：' + $publicBaseUrl)
    Write-Host ('  登录地址：' + $loginUrl)
    Write-Host ('  部署 ID：' + $DeployId)
    Write-Host ('  部署状态：' + $DeployStatus)
    Write-Host ('  App 状态：' + $appStatus)
    Write-Host ('  端口：' + $Port)
    Write-Host ('  闲置休眠：' + $IdleSeconds + ' 秒')
    Write-Host ('  网页会话：' + $SessionTtlMinutes + ' 分钟')
    Write-Host '  网页用户名：browser'
    Write-Host '  网页密码：本地 .env 的 BROWSER_PASSWORD'
    Write-Host '  root 密码：本地 .env 的 ROOT_PASSWORD'
    Write-Host ('  SSH 连接脚本：' + $(Format-DisplayPath (Join-Path $PSScriptRoot 'connect-ssh.ps1')))
    Write-Host ('  部署报告：' + $(Format-DisplayPath $reportPath))
    Write-Host ''
}
function Get-Config {
    param([string]$Name)
    $value = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if ($null -eq $value) { return '' }
    return $value
}

function Import-DotEnv {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "配置文件不存在：$Path。请先复制 .env.example 为 .env。"
    }
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        if ($line -match '^\s*$' -or $line -match '^\s*#') { continue }
        if ($line -notmatch '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') { continue }
        $name = $Matches[1]
        $value = $Matches[2].Trim()
        if ($value.Length -ge 2) {
            $first = $value.Substring(0, 1)
            $last = $value.Substring($value.Length - 1, 1)
            if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
                $value = $value.Substring(1, $value.Length - 2)
            }
        }
        if ([string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($name, 'Process'))) {
            [Environment]::SetEnvironmentVariable($name, $value, 'Process')
        }
    }
}

function Update-DotEnv {
    param([string]$Path, [string]$Name, [string]$Value)
    $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8)
    $pattern = '^\s*(?:export\s+)?' + [regex]::Escape($Name) + '\s*='
    $found = $false
    $output = foreach ($line in $lines) {
        if ($line -match $pattern) {
            $found = $true
            "$Name=$Value"
        } else {
            $line
        }
    }
    if (-not $found) {
        $output = @($output) + "$Name=$Value"
    }
    $text = (@($output) -join [Environment]::NewLine) + [Environment]::NewLine
    [IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

function New-RandomPassword {
    param([int]$Length = 32)
    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $chars = New-Object 'char[]' $Length
        $index = 0
        $limit = 256 - (256 % $alphabet.Length)
        while ($index -lt $Length) {
            $bytes = New-Object byte[] 64
            $generator.GetBytes($bytes)
            foreach ($byte in $bytes) {
                if ($byte -ge $limit) { continue }
                $chars[$index] = $alphabet[$byte % $alphabet.Length]
                $index++
                if ($index -eq $Length) { break }
            }
        }
        return -join $chars
    } finally {
        $generator.Dispose()
    }
}

function Require-Value {
    param([string]$Name, [string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "缺少配置 $Name。请填写 .env 或通过环境变量提供。"
    }
}

function Invoke-PandaStack {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path,
        [object]$Body = $null
    )
    $uri = $script:ApiBase + $Path
    $headers = @{ Authorization = 'Bearer ' + $script:ApiKey }
    try {
        if ($null -eq $Body) {
            return Invoke-RestMethod -Uri $uri -Method $Method -Headers $headers -TimeoutSec 60 -ErrorAction Stop
        }
        $json = $Body | ConvertTo-Json -Depth 20 -Compress
        return Invoke-RestMethod -Uri $uri -Method $Method -Headers $headers -ContentType 'application/json' -Body $json -TimeoutSec 60 -ErrorAction Stop
    } catch {
        $status = ''
        if ($_.Exception.Response) {
            $status = [string][int]$_.Exception.Response.StatusCode
        }
        $detail = $_.ErrorDetails.Message
        if ([string]::IsNullOrWhiteSpace($detail)) { $detail = $_.Exception.Message }
        throw "PandaStack API $Method $Path 失败，HTTP $status。$detail"
    }
}

function New-BuildCommand {
    $sourceDir = Join-Path $PSScriptRoot 'src'
    $files = @(Get-ChildItem -LiteralPath $sourceDir -File | Sort-Object Name)
    if ($files.Count -eq 0) { throw "源码目录为空：$sourceDir" }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('set -euo pipefail')
    $lines.Add('install -d -m 755 /app')
    $lines.Add('find /app -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +')
    $textExtensions = @('.sh', '.py', '.js', '.html', '.css', '.json', '.conf', '.txt', '.md')
    $textFileNames = @('sshd_config')
    foreach ($file in $files) {
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        $isText = ($textExtensions -contains $file.Extension.ToLowerInvariant()) -or ($textFileNames -contains $file.Name)
        if ($isText) {
            $content = [Text.Encoding]::UTF8.GetString($bytes)
            $content = $content.Replace("`r`n", "`n").Replace("`r", "`n")
            $bytes = [Text.UTF8Encoding]::new($false).GetBytes($content)
        }
        $encoded = [Convert]::ToBase64String($bytes)
        $lines.Add("printf '%s' '$encoded' | base64 -d > /app/$($file.Name)")
    }
    $lines.Add('bash /app/build.sh')
    $bootstrap = ($lines -join "`n") + "`n"
    $bootstrap64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($bootstrap))
    $command = "echo $bootstrap64 | base64 -d | bash"
    if ($command.Length -gt 200000) {
        throw "构建命令过长，共 $($command.Length) 个字符。请减少 src 目录中的文件。"
    }
    return $command
}

function Set-AppSecret {
    param([string]$TargetAppId, [string]$Name, [string]$Value)
    $encodedName = [uri]::EscapeDataString($Name)
    $body = [ordered]@{
        value = $Value
        secret = $true
        scope = 'production'
    }
    Invoke-PandaStack -Method 'PUT' -Path "/apps/$TargetAppId/env/$encodedName" -Body $body | Out-Null
}

function Remove-AppSecret {
    param([string]$TargetAppId, [string]$Name)
    $encodedName = [uri]::EscapeDataString($Name)
    Invoke-PandaStack -Method 'DELETE' -Path "/apps/$TargetAppId/env/$encodedName" | Out-Null
}

function Wait-Deployment {
    param([string]$TargetAppId, [string]$DeployId)
    $deadline = (Get-Date).AddMinutes(12)
    $lastStatus = ''
    while ((Get-Date) -lt $deadline) {
        $deploy = Invoke-PandaStack -Method 'GET' -Path "/apps/$TargetAppId/deploys/$DeployId"
        $status = [string]$deploy.status
        if ($status -ne $lastStatus) {
            Write-Step "部署状态：$status"
            $lastStatus = $status
        }
        if ($status -eq 'live') { return $deploy }
        if ($status -eq 'failed' -or $status -eq 'cancelled') {
            $logs = [string]$deploy.build_logs
            if ($logs.Length -gt 1600) { $logs = $logs.Substring($logs.Length - 1600) }
            throw "部署失败，状态：$status。日志末尾：`n$logs"
        }
        Start-Sleep -Seconds 5
    }
    throw '部署等待超时。请到 PandaStack 控制台查看构建日志。'
}

function Test-WebDeployment {
    param([string]$Site, [string]$Password)
    $site = Normalize-PublicBaseUrl -Value $Site -Source '网页地址'
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $true
    $handler.CookieContainer = [System.Net.CookieContainer]::new()
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(30)
    try {
        $pairs = [System.Collections.Generic.Dictionary[string,string]]::new()
        $pairs.Add('username', 'browser')
        $pairs.Add('password', $Password)
        $form = [System.Net.Http.FormUrlEncodedContent]::new($pairs)
        $login = $client.PostAsync("$site/login", $form).Result
        if ([int]$login.StatusCode -ne 303) {
            throw "登录返回 HTTP $([int]$login.StatusCode)，预期 303。"
        }
        $sessionText = $client.GetStringAsync("$site/session").Result
        $session = $sessionText | ConvertFrom-Json
        if ([string]::IsNullOrWhiteSpace([string]$session.csrf)) {
            throw '会话接口没有返回 CSRF 令牌。'
        }
        foreach ($action in @('terminal', 'browser', 'windows')) {
            $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, "$site/desktop/action")
            $request.Headers.Add('X-CSRF-Token', [string]$session.csrf)
            $json = @{ action = $action } | ConvertTo-Json -Compress
            $request.Content = [System.Net.Http.StringContent]::new($json, [Text.Encoding]::UTF8, 'application/json')
            $response = $client.SendAsync($request).Result
            $body = $response.Content.ReadAsStringAsync().Result
            if (-not $response.IsSuccessStatusCode) {
                throw "按钮 $action 返回 HTTP $([int]$response.StatusCode)：$body"
            }
            $data = $body | ConvertFrom-Json
            if (-not $data.ok) {
                throw "按钮 $action 执行失败：$body"
            }
            Write-Step "验证通过：$action"
            $request.Dispose()
            $response.Dispose()
        }
    } finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

function Wait-WebReady {
    param([string]$Site, [string]$Password)
    $site = Normalize-PublicBaseUrl -Value $Site -Source '网页地址'
    $lastError = ''
    for ($attempt = 1; $attempt -le 18; $attempt++) {
        try {
            Test-WebDeployment -Site $site -Password $Password
            return
        } catch {
            $lastError = $_.Exception.Message
            if ($attempt -lt 18) { Start-Sleep -Seconds 5 }
        }
    }
    throw "部署已经上线，但网页验证失败：$lastError"
}

Import-DotEnv -Path $EnvFile

$appName = Get-Config 'PDS_APP_NAME'
if ([string]::IsNullOrWhiteSpace($appName)) { $appName = 'pandastack-browser' }
$gitUrl = Get-Config 'PDS_GIT_URL'
if ([string]::IsNullOrWhiteSpace($gitUrl)) { $gitUrl = 'https://github.com/novnc/noVNC.git' }
$gitBranch = Get-Config 'PDS_GIT_BRANCH'
if ([string]::IsNullOrWhiteSpace($gitBranch)) { $gitBranch = 'master' }
$template = Get-Config 'PDS_TEMPLATE'
if ([string]::IsNullOrWhiteSpace($template)) { $template = 'browser' }
$portText = Get-Config 'PDS_PORT'
if ([string]::IsNullOrWhiteSpace($portText)) { $portText = '6080' }
$port = [int]$portText
if ($port -lt 1 -or $port -gt 65535) { throw 'PDS_PORT 必须在 1 到 65535 之间。' }
$idleText = Get-Config 'PDS_IDLE_TIMEOUT_SECONDS'
if ([string]::IsNullOrWhiteSpace($idleText)) { $idleText = '1800' }
$idle = [int]$idleText
if ($idle -lt 60) { throw 'PDS_IDLE_TIMEOUT_SECONDS 不能小于 60。' }
$autoHibernateText = Get-Config 'PDS_AUTO_HIBERNATE'
if ([string]::IsNullOrWhiteSpace($autoHibernateText)) { $autoHibernateText = 'true' }
$autoHibernateText = $autoHibernateText.Trim().ToLowerInvariant()
if ($autoHibernateText -notin @('true', 'false')) {
    throw 'PDS_AUTO_HIBERNATE 只能是 true 或 false。'
}
$autoHibernate = $autoHibernateText -eq 'true'

if ($appName -notmatch '^[a-z0-9][a-z0-9-]{1,62}$') {
    throw 'PDS_APP_NAME 只能使用小写字母、数字和连字符，长度为 2 到 63 个字符。'
}
try { $gitUri = [Uri]::new($gitUrl) } catch { throw 'PDS_GIT_URL 必须是公开仓库的 HTTP 或 HTTPS 地址。' }
if ($gitUrl -match '\s' -or -not $gitUri.IsAbsoluteUri -or $gitUri.Scheme -notin @('http', 'https') -or [string]::IsNullOrWhiteSpace($gitUri.Host)) {
    throw 'PDS_GIT_URL 必须是公开仓库的 HTTP 或 HTTPS 地址。'
}

if (-not [string]::IsNullOrWhiteSpace($AppId)) {
    [Environment]::SetEnvironmentVariable('PDS_APP_ID', $AppId, 'Process')
}
$targetAppId = Get-Config 'PDS_APP_ID'
if (-not [string]::IsNullOrWhiteSpace($targetAppId) -and $targetAppId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
    throw 'PDS_APP_ID 必须是 UUID。'
}
$password = Get-Config 'BROWSER_PASSWORD'
$willGeneratePassword = [string]::IsNullOrWhiteSpace($password)
if (-not $DryRun -and -not $VerifyOnly -and $willGeneratePassword) {
    $password = New-RandomPassword
    [Environment]::SetEnvironmentVariable('BROWSER_PASSWORD', $password, 'Process')
}

$rootPassword = Get-Config 'ROOT_PASSWORD'
$willGenerateRootPassword = [string]::IsNullOrWhiteSpace($rootPassword)
if (-not $DryRun -and -not $VerifyOnly -and $willGenerateRootPassword) {
    $rootPassword = New-RandomPassword
    [Environment]::SetEnvironmentVariable('ROOT_PASSWORD', $rootPassword, 'Process')
}
if (-not [string]::IsNullOrWhiteSpace($rootPassword)) {
    if ($rootPassword.Length -lt 16 -or $rootPassword.Length -gt 128 -or $rootPassword -match '[:\r\n]' -or $rootPassword -match '^\s|\s$') {
        throw 'ROOT_PASSWORD 必须是 16 到 128 个字符，不能包含冒号、换行或首尾空白。'
    }
}
if (-not [string]::IsNullOrWhiteSpace($password)) {
    if ($password.Length -lt 16 -or $password.Length -gt 128 -or $password -match '[\r\n]' -or $password -match '^\s|\s$') {
        throw 'BROWSER_PASSWORD 必须是 16 到 128 个字符，不能包含换行或首尾空白。'
    }
}

$sessionTtlText = Get-Config 'SESSION_TTL_MINUTES'
if ([string]::IsNullOrWhiteSpace($sessionTtlText)) { $sessionTtlText = '180' }
$sessionTtlMinutes = 0
if (-not [int]::TryParse($sessionTtlText, [ref]$sessionTtlMinutes)) {
    throw 'SESSION_TTL_MINUTES 必须是整数分钟数。'
}
if ($sessionTtlMinutes -lt 1 -or $sessionTtlMinutes -gt 10080) {
    throw 'SESSION_TTL_MINUTES 必须在 1 到 10080 分钟之间。'
}

$buildCommand = New-BuildCommand
$envNames = [System.Collections.Generic.List[string]]::new()
$envNames.Add('BROWSER_PASSWORD')
$envNames.Add('ROOT_PASSWORD')
$envNames.Add('SESSION_TTL_MINUTES')

$sshKeyPath = Get-Config 'SSH_PUBLIC_KEY_PATH'
$sshKeyB64 = ''
$sshKeyStatus = ''
if (-not $VerifyOnly) {
    if ($sshKeyPath -match '^(off|none|disabled|false)$') {
        $sshKeyStatus = '已禁用'
    } else {
        if ([string]::IsNullOrWhiteSpace($sshKeyPath)) {
            $sshKeyPath = '.\pandastack-root.pub'
        }
        if (-not [IO.Path]::IsPathRooted($sshKeyPath)) {
            $sshKeyPath = Join-Path $PSScriptRoot $sshKeyPath
        }
        $sshKeyPath = [IO.Path]::GetFullPath($sshKeyPath)
        if (-not $sshKeyPath.EndsWith('.pub', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'SSH_PUBLIC_KEY_PATH 必须指向 .pub 公钥文件。'
        }
        $sshPrivateKeyPath = $sshKeyPath.Substring(0, $sshKeyPath.Length - 4)
        $publicExists = Test-Path -LiteralPath $sshKeyPath -PathType Leaf
        $privateExists = Test-Path -LiteralPath $sshPrivateKeyPath -PathType Leaf
        if ($publicExists -and -not $privateExists) {
            throw "SSH 公钥存在，但私钥不存在：$sshPrivateKeyPath"
        }
        if (-not $publicExists -and $privateExists) {
            throw "SSH 私钥存在，但公钥不存在：$sshKeyPath。请恢复公钥，或删除私钥后重新部署。"
        }
        if (-not $publicExists) {
            if ($DryRun) {
                $sshKeyStatus = '将在部署时生成'
                $envNames.Add('SSH_AUTHORIZED_KEY_B64')
            } else {
                $sshKeygen = (Get-Command ssh-keygen -ErrorAction Stop).Source
                $tempDir = Join-Path ([IO.Path]::GetTempPath()) ('pds-ssh-' + [guid]::NewGuid().ToString('N'))
                New-Item -ItemType Directory -Path $tempDir | Out-Null
                $tempPrivate = Join-Path $tempDir 'pandastack-root'
                try {
                    $keygenInfo = New-Object System.Diagnostics.ProcessStartInfo
                    $keygenInfo.FileName = $sshKeygen
                    $keygenInfo.Arguments = '-q -t ed25519 -N "" -f "' + $tempPrivate + '" -C "pandastack-root"'
                    $keygenInfo.UseShellExecute = $false
                    $keygenInfo.CreateNoWindow = $true
                    $keygenProcess = [System.Diagnostics.Process]::Start($keygenInfo)
                    $keygenProcess.WaitForExit()
                    if (-not (Test-Path -LiteralPath $tempPrivate -PathType Leaf)) {
                        throw '生成 SSH 私钥失败。请确认 ssh-keygen 可用。'
                    }
                    $publicText = (& $sshKeygen -y -f $tempPrivate 2>$null) -join "`n"
                    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($publicText)) {
                        throw '导出 SSH 公钥失败。请确认 ssh-keygen 可用。'
                    }
                    [IO.File]::WriteAllText($sshKeyPath, $publicText.Trim() + "`n", (New-Object System.Text.UTF8Encoding($false)))
                    Move-Item -LiteralPath $tempPrivate -Destination $sshPrivateKeyPath -Force
                } finally {
                    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
                }
                $sshKeyStatus = '已生成'
            }
        }
        if (Test-Path -LiteralPath $sshKeyPath -PathType Leaf) {
            $sshKey = (Get-Content -LiteralPath $sshKeyPath -Raw).Trim()
            if ($sshKey -notmatch '^(ssh-|ecdsa-|sk-ssh-|sk-ecdsa-)') {
                throw 'SSH_PUBLIC_KEY_PATH 必须指向 OpenSSH 公钥文件，不能是私钥。'
            }
            $sshKeyB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($sshKey))
            $envNames.Add('SSH_AUTHORIZED_KEY_B64')
            if ([string]::IsNullOrWhiteSpace($sshKeyStatus)) { $sshKeyStatus = '已配置' }
        } elseif (-not $DryRun) {
            throw "SSH 公钥不存在：$sshKeyPath"
        }
    }
}

$databaseUrl = Get-Config 'WORKSPACE_DATABASE_URL'
$workspaceKey = Get-Config 'WORKSPACE_KEY'
$workspaceId = Get-Config 'WORKSPACE_ID'
if ([string]::IsNullOrWhiteSpace($workspaceId)) { $workspaceId = 'pandastack-workspace' }
$databaseB64 = ''
if (-not [string]::IsNullOrWhiteSpace($databaseUrl) -or -not [string]::IsNullOrWhiteSpace($workspaceKey)) {
    Require-Value 'WORKSPACE_DATABASE_URL' $databaseUrl
    Require-Value 'WORKSPACE_KEY' $workspaceKey
    if ($databaseUrl -notmatch '^postgres(ql)?://') {
        throw 'WORKSPACE_DATABASE_URL 必须以 postgres:// 或 postgresql:// 开头。'
    }
    try {
        $keyBytes = [Convert]::FromBase64String($workspaceKey)
    } catch {
        throw 'WORKSPACE_KEY 必须是有效的 Base64 字符串。'
    }
    if ($keyBytes.Length -ne 32) {
        throw 'WORKSPACE_KEY 解码后必须是 32 字节。'
    }
    $databaseB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($databaseUrl))
    $envNames.Add('DATABASE_URL_B64')
    $envNames.Add('WORKSPACE_KEY')
    $envNames.Add('WORKSPACE_ID')
}

if ($DryRun) {
    Write-Step '只检查配置，不调用 PandaStack API'
    Write-Host ('App：' + $(if ($targetAppId) { $targetAppId } else { '将新建 ' + $appName }))
    Write-Host ('模板：' + $template)
    Write-Host ('端口：' + $port)
    Write-Host ('闲置休眠：' + $idle + ' 秒')
    Write-Host ('网页会话：' + $sessionTtlMinutes + ' 分钟')
    Write-Host ('源码文件：' + @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'src') -File).Count + ' 个')
    Write-Host ('构建命令长度：' + $buildCommand.Length + ' 个字符')
    Write-Host ('将写入的密钥名：' + ($envNames -join ', '))
    if ($willGeneratePassword) { Write-Host 'BROWSER_PASSWORD：将生成随机密码' }
    else { Write-Host 'BROWSER_PASSWORD：已配置' }
    if ($willGenerateRootPassword) { Write-Host 'ROOT_PASSWORD：将生成随机密码' }
    else { Write-Host 'ROOT_PASSWORD：已配置' }
    if ($sshKeyStatus) { Write-Host ('SSH：' + $sshKeyStatus) }
    return
}

$apiKey = Get-Config 'PDS_API_KEY'
if ([string]::IsNullOrWhiteSpace($apiKey)) {
    $secure = Read-Host -Prompt 'PandaStack API Key' -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        $apiKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}
if ($apiKey -notmatch '^pds_[0-9a-f]{32}$') {
    throw 'PandaStack API Key 格式不正确。'
}
$script:ApiKey = $apiKey

if ($VerifyOnly) {
    Require-Value 'PDS_APP_ID' $targetAppId
    Require-Value 'BROWSER_PASSWORD' $password
    Write-Step '只验证现有 App，不修改配置或重新部署'
    $existing = Invoke-PandaStack -Method 'GET' -Path "/apps/$targetAppId"
    $configuredUrl = Get-Config 'PDS_PUBLIC_URL'
    $fallbackUrl = if (-not [string]::IsNullOrWhiteSpace($configuredUrl)) { $configuredUrl } else { "https://$targetAppId.pandastack.ai" }
    $publicBaseUrl = Get-AppPublicBaseUrl -App $existing -Fallback $fallbackUrl
    Wait-WebReady -Site $publicBaseUrl -Password $password
    Write-DeploymentSummary -AppId $targetAppId -AppName $appName -App $existing -DeployId '' -DeployStatus 'verified' -Port $port -IdleSeconds $idle -SessionTtlMinutes $sessionTtlMinutes
    Write-Step '验证完成'
    return
}

if ($willGeneratePassword) {
    Update-DotEnv -Path $EnvFile -Name 'BROWSER_PASSWORD' -Value $password
    Write-Step '已生成随机网页密码并写入本地 .env'
}
if ($willGenerateRootPassword) {
    Update-DotEnv -Path $EnvFile -Name 'ROOT_PASSWORD' -Value $rootPassword
    Write-Step '已生成随机 root 密码并写入本地 .env'
}

$appFields = [ordered]@{
    git_branch = $gitBranch
    template = $template
    port = $port
    start_command = 'bash /app/start-browser.sh'
    install_command = 'true'
    framework = 'generic'
    auto_deploy = $false
    auto_hibernate = $autoHibernate
    idle_timeout_seconds = $idle
    build_command = $buildCommand
}

if ([string]::IsNullOrWhiteSpace($targetAppId)) {
    Write-Step "创建 App：$appName"
    $createBody = [ordered]@{
        name = $appName
        git_url = $gitUrl
        max_instances = 1
    }
    foreach ($key in $appFields.Keys) { $createBody[$key] = $appFields[$key] }
    $created = Invoke-PandaStack -Method 'POST' -Path '/apps' -Body $createBody
    $targetAppId = [string]$created.id
    if ([string]::IsNullOrWhiteSpace($targetAppId)) {
        throw 'PandaStack 没有返回新 App 的 ID。'
    }
    Update-DotEnv -Path $EnvFile -Name 'PDS_APP_ID' -Value $targetAppId
    Write-Step "App 已创建：$targetAppId"
} else {
    Write-Step "更新 App：$targetAppId"
    $existing = Invoke-PandaStack -Method 'GET' -Path "/apps/$targetAppId"
    if ([string]$existing.git_url -ne $gitUrl) {
        throw "现有 App 的 git_url 是 $($existing.git_url)，与配置中的 $gitUrl 不一致。git_url 不能在更新接口中修改。"
    }
    Invoke-PandaStack -Method 'PATCH' -Path "/apps/$targetAppId" -Body $appFields | Out-Null
}

Write-Step '写入加密环境变量'
Set-AppSecret -TargetAppId $targetAppId -Name 'BROWSER_PASSWORD' -Value $password
Set-AppSecret -TargetAppId $targetAppId -Name 'ROOT_PASSWORD' -Value $rootPassword
Set-AppSecret -TargetAppId $targetAppId -Name 'SESSION_TTL_MINUTES' -Value ([string]$sessionTtlMinutes)
if (-not [string]::IsNullOrWhiteSpace($sshKeyB64)) {
    Set-AppSecret -TargetAppId $targetAppId -Name 'SSH_AUTHORIZED_KEY_B64' -Value $sshKeyB64
} else {
    Remove-AppSecret -TargetAppId $targetAppId -Name 'SSH_AUTHORIZED_KEY_B64'
}
if (-not [string]::IsNullOrWhiteSpace($databaseB64)) {
    Set-AppSecret -TargetAppId $targetAppId -Name 'DATABASE_URL_B64' -Value $databaseB64
    Set-AppSecret -TargetAppId $targetAppId -Name 'WORKSPACE_KEY' -Value $workspaceKey
    Set-AppSecret -TargetAppId $targetAppId -Name 'WORKSPACE_ID' -Value $workspaceId
} else {
    Remove-AppSecret -TargetAppId $targetAppId -Name 'DATABASE_URL_B64'
    Remove-AppSecret -TargetAppId $targetAppId -Name 'WORKSPACE_KEY'
    Remove-AppSecret -TargetAppId $targetAppId -Name 'WORKSPACE_ID'
}

Write-Step '触发部署'
$deploy = Invoke-PandaStack -Method 'POST' -Path "/apps/$targetAppId/deploys" -Body @{}
$deployId = [string]$deploy.id
if ([string]::IsNullOrWhiteSpace($deployId)) {
    throw 'PandaStack 没有返回部署 ID。'
}
Write-Step "部署 ID：$deployId"
$result = Wait-Deployment -TargetAppId $targetAppId -DeployId $deployId
Write-Step '部署已上线'

$appDetails = Invoke-PandaStack -Method 'GET' -Path "/apps/$targetAppId"
$configuredUrl = Get-Config 'PDS_PUBLIC_URL'
$fallbackUrl = if (-not [string]::IsNullOrWhiteSpace($configuredUrl)) { $configuredUrl } else { "https://$targetAppId.pandastack.ai" }
$publicBaseUrl = Get-AppPublicBaseUrl -App $appDetails -Fallback $fallbackUrl
Update-DotEnv -Path $EnvFile -Name 'PDS_PUBLIC_URL' -Value $publicBaseUrl
Write-DeploymentSummary -AppId $targetAppId -AppName $appName -App $appDetails -DeployId $deployId -DeployStatus ([string]$result.status) -Port $port -IdleSeconds $idle -SessionTtlMinutes $sessionTtlMinutes

if (-not $SkipVerify) {
    Write-Step '验证登录、会话和桌面按钮'
    Wait-WebReady -Site $publicBaseUrl -Password $password
    Write-Step '验证完成'
}

Write-Host '部署完成。'
