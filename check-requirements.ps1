param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '.env')
)

$ErrorActionPreference = 'Stop'
$checks = New-Object 'System.Collections.Generic.List[object]'

function Add-Check {
    param([string]$Name, [bool]$Ok, [string]$Detail)
    $checks.Add([pscustomobject]@{ Check = $Name; Ok = $Ok; Detail = $Detail })
}

function Read-DotEnv {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @{}
    }
    $values = @{}
    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    foreach ($line in ($text -split "`r?`n")) {
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

$psOk = $PSVersionTable.PSVersion -ge [version]'5.1'
Add-Check 'PowerShell' $psOk ('当前版本 ' + $PSVersionTable.PSVersion.ToString() + '，要求 5.1 或更高')

$python = Get-Command python -ErrorAction SilentlyContinue
$pythonOk = $false
$pythonDetail = '未找到 python 命令'
if ($python) {
    try {
        $versionOutput = & $python.Source -c "import sys; print('%d.%d' % sys.version_info[:2])" 2>$null
        $versionExit = $LASTEXITCODE
        $versionText = [string](@($versionOutput)[0])
        $pythonOk = ($versionExit -eq 0) -and ([version]$versionText -ge [version]'3.10')
        $pythonDetail = '当前版本 ' + $versionText + '，要求 3.10 或更高'
    } catch {
        $pythonDetail = '无法执行 python'
    }
}
Add-Check 'Python' $pythonOk $pythonDetail

$sshPath = Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$sshOk = Test-Path -LiteralPath $sshPath -PathType Leaf
Add-Check 'OpenSSH Client' $sshOk $(if ($sshOk) { Format-DisplayPath $sshPath } else { '未找到 Windows OpenSSH Client' })
$sshKeygenPath = Join-Path $env:WINDIR 'System32\OpenSSH\ssh-keygen.exe'
$sshKeygenOk = Test-Path -LiteralPath $sshKeygenPath -PathType Leaf
Add-Check 'OpenSSH ssh-keygen' $sshKeygenOk $(if ($sshKeygenOk) { Format-DisplayPath $sshKeygenPath } else { '未找到 ssh-keygen，首次部署无法自动生成密钥' })

foreach ($file in @('ssh_bridge.py', 'websocket_client-1.9.2-py3-none-any.whl', 'connect-ssh.ps1', 'deploy.ps1', 'THIRD_PARTY_NOTICES.md')) {
    $filePath = Join-Path $PSScriptRoot $file
    Add-Check ('文件 ' + $file) (Test-Path -LiteralPath $filePath -PathType Leaf) $(Format-DisplayPath $filePath)
}

$wheelPath = Join-Path $PSScriptRoot 'websocket_client-1.9.2-py3-none-any.whl'
$expectedWheelHash = 'e1a673830a9c7bfa47b1cd3d5e4178f4c9651d80a4eab02c9c23a1c3ec6250ce'
$wheelHashOk = $false
$wheelHashDetail = 'wheel 文件不存在'
if (Test-Path -LiteralPath $wheelPath -PathType Leaf) {
    $actualWheelHash = (Get-FileHash -LiteralPath $wheelPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $wheelHashOk = $actualWheelHash -eq $expectedWheelHash
    $wheelHashDetail = $actualWheelHash
}
Add-Check 'websocket-client wheel SHA-256' $wheelHashOk $wheelHashDetail

$config = Read-DotEnv -Path $EnvFile
Add-Check '.env 文件' (Test-Path -LiteralPath $EnvFile -PathType Leaf) $(Format-DisplayPath $EnvFile)
foreach ($name in @('PDS_API_KEY', 'PDS_APP_ID', 'BROWSER_PASSWORD', 'SSH_PUBLIC_KEY_PATH')) {
    $value = [string]$config[$name]
    $detail = if ([string]::IsNullOrWhiteSpace($value)) {
        if ($name -eq 'SSH_PUBLIC_KEY_PATH') { '未填写，使用默认路径' } else { '未填写，部署时按需生成或留空' }
    } elseif ($name -eq 'SSH_PUBLIC_KEY_PATH' -and $value -match '^(off|none|disabled|false)$') {
        '已禁用'
    } else {
        '已填写'
    }
    Add-Check ('.env ' + $name) $true $detail
}

$apiKey = [string]$config['PDS_API_KEY']
if (-not [string]::IsNullOrWhiteSpace($apiKey)) {
    Add-Check '.env PDS_API_KEY 格式' ($apiKey -match '^pds_[0-9a-f]{32}$') 'pds_ 加 32 位小写十六进制'
}

$appId = [string]$config['PDS_APP_ID']
if (-not [string]::IsNullOrWhiteSpace($appId)) {
    Add-Check '.env PDS_APP_ID 格式' ($appId -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') 'UUID'
}

$publicUrl = [string]$config['PDS_PUBLIC_URL']
if (-not [string]::IsNullOrWhiteSpace($publicUrl)) {
    $publicUrlOk = Test-HttpsOrigin $publicUrl
    $publicUrlDetail = if ($publicUrlOk) { '格式正确' } else { '必须是 HTTPS 源地址，不能包含账号信息、路径、查询参数或片段' }
    Add-Check '.env PDS_PUBLIC_URL' $publicUrlOk $publicUrlDetail
}

$browserPassword = [string]$config['BROWSER_PASSWORD']
if (-not [string]::IsNullOrWhiteSpace($browserPassword)) {
    $browserPasswordOk = $browserPassword.Length -ge 16 -and $browserPassword.Length -le 128 -and $browserPassword -notmatch '[\r\n]' -and $browserPassword -notmatch '^\s|\s$'
    Add-Check '.env BROWSER_PASSWORD 长度' $browserPasswordOk '16 到 128 个字符，不能包含换行'
}

$rootPassword = [string]$config['ROOT_PASSWORD']
if (-not [string]::IsNullOrWhiteSpace($rootPassword)) {
    $rootPasswordOk = $rootPassword.Length -ge 16 -and $rootPassword.Length -le 128 -and $rootPassword -notmatch '[:\r\n]' -and $rootPassword -notmatch '^\s|\s$'
    Add-Check '.env ROOT_PASSWORD 长度' $rootPasswordOk '16 到 128 个字符，不能包含冒号或换行'
}

$sessionTtlText = [string]$config['SESSION_TTL_MINUTES']
if ([string]::IsNullOrWhiteSpace($sessionTtlText)) { $sessionTtlText = '180' }
$sessionTtl = 0
$sessionTtlOk = [int]::TryParse($sessionTtlText, [ref]$sessionTtl)
if ($sessionTtlOk) { $sessionTtlOk = $sessionTtl -ge 1 -and $sessionTtl -le 10080 }
$sessionTtlDetail = if ($sessionTtlOk) {
    $sessionTtlText + ' 分钟，范围 1 到 10080'
} else {
    '必须是 1 到 10080 之间的整数分钟数'
}
Add-Check '.env SESSION_TTL_MINUTES' $sessionTtlOk $sessionTtlDetail

$publicKey = [string]$config['SSH_PUBLIC_KEY_PATH']
if ($publicKey -match '^(off|none|disabled|false)$') {
    Add-Check 'SSH' $true '已禁用'
} else {
    if ([string]::IsNullOrWhiteSpace($publicKey)) {
        $publicKey = '.\pandastack-root.pub'
    }
    if (-not [IO.Path]::IsPathRooted($publicKey)) {
        $publicKey = Join-Path $PSScriptRoot $publicKey
    }
    $publicKey = [IO.Path]::GetFullPath($publicKey)
    if (-not $publicKey.EndsWith('.pub', [StringComparison]::OrdinalIgnoreCase)) {
        Add-Check 'SSH 公钥文件' $false 'SSH_PUBLIC_KEY_PATH 必须指向 .pub 公钥文件'
    } else {
        $privateKey = $publicKey.Substring(0, $publicKey.Length - 4)
        $publicOk = Test-Path -LiteralPath $publicKey -PathType Leaf
        $privateOk = Test-Path -LiteralPath $privateKey -PathType Leaf
        if (-not $publicOk -and -not $privateOk) {
            Add-Check 'SSH 密钥' $true '将在首次部署时生成'
        } else {
            Add-Check 'SSH 公钥文件' $publicOk $(Format-DisplayPath $publicKey)
            Add-Check 'SSH 私钥文件' $privateOk $(Format-DisplayPath $privateKey)
        }
    }
}

if ($pythonOk) {
    $wheel = $wheelPath
    try {
        $wsOutput = & $python.Source -c "import sys; sys.path.insert(0, sys.argv[1]); import websocket; print(websocket.__version__)" $wheel 2>$null
        $wsExit = $LASTEXITCODE
        $wsVersion = @($wsOutput)[0]
        $wsOk = ($wsExit -eq 0) -and (-not [string]::IsNullOrWhiteSpace([string]$wsVersion))
        Add-Check 'websocket-client' $wsOk ('版本 ' + [string]$wsVersion)
    } catch {
        Add-Check 'websocket-client' $false '无法从 websocket_client-1.9.2-py3-none-any.whl 导入'
    }
}

Write-Host ''
Write-Host '本地环境检查结果'
foreach ($check in $checks) {
    $mark = if ($check.Ok) { 'OK' } else { 'FAIL' }
    Write-Host ('  [' + $mark + '] ' + $check.Check + '：' + $check.Detail)
}
Write-Host ''

$failed = @($checks | Where-Object { -not $_.Ok })
if ($failed.Count -gt 0) {
    Write-Host ('检查未通过，共 ' + $failed.Count + ' 项。')
    exit 1
}
Write-Host '检查通过。'
exit 0