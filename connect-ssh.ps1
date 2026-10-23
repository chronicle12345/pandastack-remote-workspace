param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '.env'),
    [string]$PrivateKey = '',
    [string]$RemoteCommand = '',
    [string]$Proxy = ''
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http

function Read-DotEnv {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "配置文件不存在：$(Format-DisplayPath $Path)"
    }
    $values = @{}
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
        $values[$name] = $value
    }
    return $values
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

function Test-HttpsOrigin {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -match '\s' -or $Value.Contains('?') -or $Value.Contains('#') -or $Value -match '^https://[^/?#]*@' -or $Value -match '^https://[^/?#]+:(?:/|$)') {
        return $false
    }
    try {
        $uri = [Uri]::new($Value)
        $port = $uri.Port
    } catch {
        return $false
    }
    return (-not (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https' -or [string]::IsNullOrWhiteSpace($uri.Host) -or $uri.UserInfo -or $uri.AbsolutePath -notin @('', '/') -or $uri.Query -or $uri.Fragment -or $port -lt 1 -or $port -gt 65535))
}

function New-WebProxy {
    param([string]$ProxyUrl)
    if ([string]::IsNullOrWhiteSpace($ProxyUrl)) { return $null }
    if ($ProxyUrl -notmatch '^http://[^/?#]+:[0-9]+/?$') { throw '代理地址必须是 http://host:port。' }
    try { $proxyUri = [Uri]::new($ProxyUrl) } catch { throw '代理地址无效。' }
    if ($proxyUri.Scheme -ne 'http' -or [string]::IsNullOrWhiteSpace($proxyUri.Host) -or $proxyUri.Port -lt 1 -or $proxyUri.Port -gt 65535) {
        throw '代理地址必须是 http://host:port。'
    }
    $proxy = [System.Net.WebProxy]::new($proxyUri)
    if (-not [string]::IsNullOrWhiteSpace($proxyUri.UserInfo)) {
        $parts = $proxyUri.UserInfo.Split(':', 2)
        $user = [Uri]::UnescapeDataString($parts[0])
        $pass = if ($parts.Length -gt 1) { [Uri]::UnescapeDataString($parts[1]) } else { '' }
        $proxy.Credentials = [System.Net.NetworkCredential]::new($user, $pass)
    }
    return $proxy
}

function New-BrowserSession {
    param([string]$Site, [string]$Password, [string]$SessionPath, [string]$ProxyUrl)
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $true
    $handler.CookieContainer = [System.Net.CookieContainer]::new()
    $handler.UseProxy = $false
    $proxy = New-WebProxy -ProxyUrl $ProxyUrl
    if ($null -ne $proxy) {
        $handler.UseProxy = $true
        $handler.Proxy = $proxy
    }
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(30)
    try {
        $pairs = [System.Collections.Generic.Dictionary[string,string]]::new()
        $pairs.Add('username', 'browser')
        $pairs.Add('password', $Password)
        $form = [System.Net.Http.FormUrlEncodedContent]::new($pairs)
        try {
            $login = $client.PostAsync("$Site/login", $form).Result
        } finally {
            $form.Dispose()
        }
        try {
            if ([int]$login.StatusCode -ne 303) {
                $body = $login.Content.ReadAsStringAsync().Result
                throw "网页登录返回 HTTP $([int]$login.StatusCode)：$body"
            }
        } finally {
            $login.Dispose()
        }
        $cookies = $handler.CookieContainer.GetCookies([Uri]$Site)
        $cookie = $cookies['__Host-browser_session']
        if (-not $cookie) { throw '网页登录没有返回会话 Cookie。' }
        $session = [ordered]@{
            url = $Site
            cookie = '__Host-browser_session=' + $cookie.Value
            proxy = $ProxyUrl
        }
        $json = $session | ConvertTo-Json -Compress
        [IO.File]::WriteAllText($SessionPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    } finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

$config = Read-DotEnv -Path $EnvFile
$appId = [string]$config['PDS_APP_ID']
$publicUrl = [string]$config['PDS_PUBLIC_URL']
$browserPassword = [string]$config['BROWSER_PASSWORD']
if ([string]::IsNullOrWhiteSpace($appId)) { throw '.env 缺少 PDS_APP_ID。' }
if ($appId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { throw '.env PDS_APP_ID 必须是 UUID。' }
if ([string]::IsNullOrWhiteSpace($browserPassword)) { throw '.env 缺少 BROWSER_PASSWORD。' }
if (-not [string]::IsNullOrWhiteSpace($publicUrl) -and -not (Test-HttpsOrigin $publicUrl)) {
    throw 'PDS_PUBLIC_URL 必须是 HTTPS 源地址，不能包含账号信息、路径、查询参数或片段。'
}

if ([string]::IsNullOrWhiteSpace($PrivateKey)) {
    $publicKey = [string]$config['SSH_PUBLIC_KEY_PATH']
    if ($publicKey -match '^(off|none|disabled|false)$') {
        throw 'SSH 已在 .env 中禁用。把 SSH_PUBLIC_KEY_PATH 改为 .\pandastack-root.pub 后重新部署。'
    }
    if ([string]::IsNullOrWhiteSpace($publicKey)) {
        $publicKey = '.\pandastack-root.pub'
    }
    if (-not [IO.Path]::IsPathRooted($publicKey)) {
        $publicKey = Join-Path $PSScriptRoot $publicKey
    }
    if ($publicKey.EndsWith('.pub', [StringComparison]::OrdinalIgnoreCase)) {
        $PrivateKey = $publicKey.Substring(0, $publicKey.Length - 4)
    } else {
        $PrivateKey = $publicKey
    }
}
if (-not [IO.Path]::IsPathRooted($PrivateKey)) {
    $PrivateKey = Join-Path $PSScriptRoot $PrivateKey
}
$PrivateKey = [IO.Path]::GetFullPath($PrivateKey)
if (-not (Test-Path -LiteralPath $PrivateKey -PathType Leaf)) {
    throw "SSH 私钥不存在：$(Format-DisplayPath $PrivateKey)"
}

$python = (Get-Command python -ErrorAction Stop).Source
$bridge = Join-Path $PSScriptRoot 'ssh_bridge.py'
$session = Join-Path $PSScriptRoot '.ssh-session.json'
$url = if ([string]::IsNullOrWhiteSpace($publicUrl)) { "https://$appId.pandastack.ai" } else { $publicUrl.TrimEnd('/') }
if (-not (Test-HttpsOrigin $url)) {
    throw 'PDS_PUBLIC_URL 必须是 HTTPS 源地址，不能包含账号信息、路径、查询参数或片段。'
}
$url = ([Uri]::new($url)).GetLeftPart([UriPartial]::Authority)
if (-not (Test-Path -LiteralPath $bridge -PathType Leaf)) {
    throw "SSH 桥接脚本不存在：$(Format-DisplayPath $bridge)"
}

New-BrowserSession -Site $url -Password $browserPassword -SessionPath $session -ProxyUrl $Proxy
Write-Host '网页登录成功，正在建立 SSH 连接。'

$proxyCommand = '"' + $python + '" "' + $bridge + '" connect --url ' + $url + ' --session "' + $session + '"'
if (-not [string]::IsNullOrWhiteSpace($Proxy)) {
    $proxyCommand += ' --proxy "' + $Proxy + '"'
}

$ssh = Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$sshArgs = @(
    '-F', 'NUL',
    '-o', "ProxyCommand=$proxyCommand",
    '-o', 'StrictHostKeyChecking=no',
    '-o', 'UserKnownHostsFile=NUL',
    '-o', 'GlobalKnownHostsFile=NUL',
    '-o', 'IdentitiesOnly=yes',
    '-o', 'IdentityAgent=none',
    '-o', 'ForwardAgent=no',
    '-i', $PrivateKey
)
if ([string]::IsNullOrWhiteSpace($RemoteCommand)) {
    $sshArgs += @('-t', 'root@pandastack-dev', 'cd /workspace; exec bash -l')
} else {
    $sshArgs += @('root@pandastack-dev', $RemoteCommand)
}
$exitCode = 1
try {
    & $ssh @sshArgs
    $exitCode = $LASTEXITCODE
} finally {
    Remove-Item -LiteralPath $session -Force -ErrorAction SilentlyContinue
}
exit $exitCode