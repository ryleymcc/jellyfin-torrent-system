param(
    [string]$RemoteHost = $env:DEPLOY_SSH_HOST,
    [string]$RemoteUser = $env:DEPLOY_SSH_USER,
    [int]$RemotePort = $(if ($env:DEPLOY_SSH_PORT) { [int]$env:DEPLOY_SSH_PORT } else { 22 }),
    [string]$JellyfinDomain = $env:JELLYFIN_DOMAIN,
    [string]$LetsEncryptEmail = $env:LETSENCRYPT_EMAIL,
    [string]$RemoteAppRoot = $(if ($env:REMOTE_APP_ROOT) { $env:REMOTE_APP_ROOT } else { "~/jellyfin-app" }),
    [string]$RemoteStorageRoot = $env:REMOTE_STORAGE_ROOT,
    [string]$RemoteStorageLink = $env:REMOTE_STORAGE_LINK,
    [string]$Timezone = $(if ($env:TZ) { $env:TZ } else { "UTC" }),
    [string]$JellyfinPublishedUrl = $env:JELLYFIN_PUBLISHED_URL,
    [string]$SudoPassword = $env:DEPLOY_SUDO_PASSWORD,
    [string]$SudoPasswordFile = $env:DEPLOY_SUDO_PASSWORD_FILE,
    [string]$QbittorrentUsername = $env:QBITTORRENT_USERNAME,
    [string]$QbittorrentPassword = $env:QBITTORRENT_PASSWORD,
    [int]$QbittorrentWebUiPort = $(if ($env:QBITTORRENT_WEBUI_PORT) { [int]$env:QBITTORRENT_WEBUI_PORT } else { 8080 }),
    [int]$QbittorrentTorrentPort = $(if ($env:QBITTORRENT_TORRENT_PORT) { [int]$env:QBITTORRENT_TORRENT_PORT } else { 6881 }),
    [switch]$EnableDlna = $false,
    [switch]$SkipPlugin,
    [int]$ProbeTimeoutSeconds = 900,
    [string]$EnvFile = $env:DEPLOY_ENV_FILE
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Get-PlainTextSecureString {
    param([System.Security.SecureString]$SecureString)

    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

function Resolve-RequiredValue {
    param(
        [string]$Name,
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "Missing required setting: $Name"
    }

    return $Value.Trim()
}

function Import-EnvFile {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) {
        return
    }

    foreach ($rawLine in Get-Content -Path $Path) {
        $line = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) {
            continue
        }

        $parts = $line -split '=', 2
        if ($parts.Count -ne 2 -or [string]::IsNullOrWhiteSpace($parts[0])) {
            continue
        }

        $name = $parts[0].Trim()
        $value = $parts[1].Trim()
        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }

        Set-Item -Path "Env:$name" -Value $value
    }
}

function Get-BooleanValue {
    param(
        [object]$Value,
        [bool]$Default = $false
    )

    if ($Value -is [bool]) {
        return [bool]$Value
    }

    if ($null -eq $Value) {
        return $Default
    }

    $text = $Value.ToString().Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $Default
    }

    switch ($text) {
        "1" { return $true }
        "true" { return $true }
        "yes" { return $true }
        "on" { return $true }
        "0" { return $false }
        "false" { return $false }
        "no" { return $false }
        "off" { return $false }
        default { throw "Could not parse boolean value: $Value" }
    }
}

function New-RandomSecret {
    param([int]$Length = 24)

    $alphabet = "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    $bytes = New-Object byte[] $Length
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)

    $builder = New-Object System.Text.StringBuilder
    foreach ($byte in $bytes) {
        [void]$builder.Append($alphabet[$byte % $alphabet.Length])
    }

    return $builder.ToString()
}

function Format-Command {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    $parts = @($FilePath)
    foreach ($argument in $Arguments) {
        if ($argument -match '\s') {
            $parts += '"' + $argument.Replace('"', '\"') + '"'
        }
        else {
            $parts += $argument
        }
    }

    return ($parts -join ' ')
}

function Invoke-NativeCommand {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$ErrorMessage = "Command failed",
        [string]$StandardInput
    )

    Write-Host ">> $(Format-Command -FilePath $FilePath -Arguments $Arguments)"

    if ($PSBoundParameters.ContainsKey('StandardInput')) {
        $previousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $output = $StandardInput | & $FilePath @Arguments 2>&1
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }

        if ($output) {
            $output | ForEach-Object { Write-Host $_ }
        }

        if ($LASTEXITCODE -ne 0) {
            throw "$ErrorMessage`n$($output -join "`n")"
        }

        return
    }
    else {
        & $FilePath @Arguments
    }

    if ($LASTEXITCODE -ne 0) {
        throw $ErrorMessage
    }
}

function Invoke-NativeCapture {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$ErrorMessage = "Command failed"
    )

    Write-Host ">> $(Format-Command -FilePath $FilePath -Arguments $Arguments)"
    $output = & $FilePath @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "$ErrorMessage`n$($output -join "`n")"
    }

    return ($output -join "`n").Trim()
}

function ConvertTo-ShellLiteral {
    param([string]$Value)

    return "'" + $Value.Replace("'", "'""'""'") + "'"
}

function ConvertTo-XmlText {
    param([string]$Value)

    if ($null -eq $Value) {
        return ''
    }

    return [System.Security.SecurityElement]::Escape($Value)
}

function Resolve-RemotePath {
    param(
        [string]$Path,
        [string]$RemoteHome
    )

    $trimmed = $Path.Trim()
    if ($trimmed -eq "~") {
        return $RemoteHome
    }

    if ($trimmed.StartsWith("~/", [System.StringComparison]::Ordinal)) {
        return ($RemoteHome.TrimEnd('/') + "/" + $trimmed.Substring(2))
    }

    if ($trimmed.StartsWith("/")) {
        return $trimmed
    }

    return ($RemoteHome.TrimEnd('/') + "/" + $trimmed.TrimStart('./'))
}

function Assert-NoWhitespacePath {
    param(
        [string]$Name,
        [string]$Value
    )

    if ($Value -match '\s') {
        throw "$Name cannot contain whitespace in this deployment flow: $Value"
    }
}

function Get-RemoteFacts {
    param(
        [string]$HostName,
        [string]$User,
        [int]$Port
    )

    $remoteCommand = 'printf ''%s|%s|%s|%s'' "$HOME" "$(id -u)" "$(id -g)" "$(uname -m)"'
    $sshArgs = @('-p', $Port.ToString(), "${User}@${HostName}", $remoteCommand)
    $output = Invoke-NativeCapture -FilePath 'ssh' -Arguments $sshArgs -ErrorMessage 'Remote preflight failed'
    $lines = $output -split '\|'

    if ($lines.Count -lt 4) {
        throw "Remote preflight did not return the expected data."
    }

    return [pscustomobject]@{
        Home = $lines[0].Trim()
        Uid = [int]$lines[1].Trim()
        Gid = [int]$lines[2].Trim()
        Architecture = $lines[3].Trim()
    }
}

function Get-DockerPlatform {
    param([string]$Architecture)

    switch ($Architecture) {
        { $_ -in @('x86_64', 'amd64') } { return 'linux/amd64' }
        { $_ -in @('aarch64', 'arm64') } { return 'linux/arm64' }
        default { throw "Unsupported remote architecture: $Architecture. Only amd64 and arm64 are supported." }
    }
}

function Expand-Template {
    param(
        [string]$TemplatePath,
        [hashtable]$Tokens
    )

    $content = Get-Content -Raw -Path $TemplatePath
    foreach ($token in $Tokens.Keys) {
        $content = $content.Replace($token, [string]$Tokens[$token])
    }

    return $content
}

function Set-AsciiLfContent {
    param(
        [string]$Path,
        [string]$Content
    )

    $normalized = ($Content -replace "`r`n", "`n") -replace "`r", "`n"
    if (-not $normalized.EndsWith("`n", [System.StringComparison]::Ordinal)) {
        $normalized += "`n"
    }

    [System.IO.File]::WriteAllText($Path, $normalized, [System.Text.Encoding]::ASCII)
}

function Wait-ForProbe {
    param(
        [string]$Url,
        [int]$TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $response = Invoke-WebRequest -Uri $Url -Method Get -TimeoutSec 10 -UseBasicParsing
            if ($response.StatusCode -eq 200) {
                return
            }
        }
        catch {
        }

        Start-Sleep -Seconds 5
    }

    throw "Timed out waiting for $Url to return HTTP 200. Create the Cloudflare record for $JellyfinDomain and make sure port 80 reaches this host."
}

function Build-PluginArtifact {
    param(
        [string]$ProjectPath,
        [string]$Configuration = "Release"
    )

    Invoke-NativeCommand -FilePath 'dotnet' -Arguments @('build', $ProjectPath, '-c', $Configuration) -ErrorMessage 'Plugin build failed' | Out-Host

    $resolvedProjectPath = (Resolve-Path $ProjectPath).Path
    $pluginRoot = Split-Path $resolvedProjectPath -Parent
    $pluginName = [System.IO.Path]::GetFileNameWithoutExtension($resolvedProjectPath)
    $outputRoot = Join-Path $pluginRoot "bin\$Configuration"

    $dllPath = Get-ChildItem -Path $outputRoot -Filter "$pluginName.dll" -File -Recurse |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1 -ExpandProperty FullName

    if (-not $dllPath) {
        throw "Built plugin assembly not found under $outputRoot"
    }

    $pluginVersion = [System.Reflection.AssemblyName]::GetAssemblyName($dllPath).Version.ToString()
    if ([string]::IsNullOrWhiteSpace($pluginVersion)) {
        throw "Could not determine plugin version from $dllPath"
    }

    return [pscustomobject]@{
        DllPath = $dllPath
        FileName = [System.IO.Path]::GetFileName($dllPath)
        DirectoryName = "${pluginName}_${pluginVersion}"
    }
}

$workspaceRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$templateRoot = Join-Path $PSScriptRoot 'templates'
$pluginProjectPath = Join-Path $workspaceRoot 'MyJellyfinPlugin\MyJellyfinPlugin.csproj'
$torrentSearchSource = Join-Path $workspaceRoot 'Torrent-Search-API'
$buildScriptPath = Join-Path $PSScriptRoot 'build_app.ps1'

if ([string]::IsNullOrWhiteSpace($EnvFile)) {
    $EnvFile = Join-Path $PSScriptRoot 'deploy.env'
}

Import-EnvFile -Path $EnvFile

if (-not $PSBoundParameters.ContainsKey('RemoteHost')) { $RemoteHost = $env:DEPLOY_SSH_HOST }
if (-not $PSBoundParameters.ContainsKey('RemoteUser')) { $RemoteUser = $env:DEPLOY_SSH_USER }
if (-not $PSBoundParameters.ContainsKey('RemotePort') -and $env:DEPLOY_SSH_PORT) { $RemotePort = [int]$env:DEPLOY_SSH_PORT }
if (-not $PSBoundParameters.ContainsKey('JellyfinDomain')) { $JellyfinDomain = $env:JELLYFIN_DOMAIN }
if (-not $PSBoundParameters.ContainsKey('LetsEncryptEmail')) { $LetsEncryptEmail = $env:LETSENCRYPT_EMAIL }
if (-not $PSBoundParameters.ContainsKey('RemoteAppRoot') -and $env:REMOTE_APP_ROOT) { $RemoteAppRoot = $env:REMOTE_APP_ROOT }
if (-not $PSBoundParameters.ContainsKey('RemoteStorageRoot')) { $RemoteStorageRoot = $env:REMOTE_STORAGE_ROOT }
if (-not $PSBoundParameters.ContainsKey('RemoteStorageLink')) { $RemoteStorageLink = $env:REMOTE_STORAGE_LINK }
if (-not $PSBoundParameters.ContainsKey('Timezone') -and $env:TZ) { $Timezone = $env:TZ }
if (-not $PSBoundParameters.ContainsKey('JellyfinPublishedUrl')) { $JellyfinPublishedUrl = $env:JELLYFIN_PUBLISHED_URL }
if (-not $PSBoundParameters.ContainsKey('SudoPassword')) { $SudoPassword = $env:DEPLOY_SUDO_PASSWORD }
if (-not $PSBoundParameters.ContainsKey('SudoPasswordFile')) { $SudoPasswordFile = $env:DEPLOY_SUDO_PASSWORD_FILE }
if (-not $PSBoundParameters.ContainsKey('QbittorrentUsername')) { $QbittorrentUsername = $env:QBITTORRENT_USERNAME }
if (-not $PSBoundParameters.ContainsKey('QbittorrentPassword')) { $QbittorrentPassword = $env:QBITTORRENT_PASSWORD }
if (-not $PSBoundParameters.ContainsKey('QbittorrentWebUiPort') -and $env:QBITTORRENT_WEBUI_PORT) { $QbittorrentWebUiPort = [int]$env:QBITTORRENT_WEBUI_PORT }
if (-not $PSBoundParameters.ContainsKey('QbittorrentTorrentPort') -and $env:QBITTORRENT_TORRENT_PORT) { $QbittorrentTorrentPort = [int]$env:QBITTORRENT_TORRENT_PORT }

$RemoteHost = Resolve-RequiredValue -Name 'DEPLOY_SSH_HOST' -Value $RemoteHost
$RemoteUser = Resolve-RequiredValue -Name 'DEPLOY_SSH_USER' -Value $RemoteUser
$JellyfinDomain = Resolve-RequiredValue -Name 'JELLYFIN_DOMAIN' -Value $JellyfinDomain
$LetsEncryptEmail = Resolve-RequiredValue -Name 'LETSENCRYPT_EMAIL' -Value $LetsEncryptEmail
$RemoteStorageRoot = Resolve-RequiredValue -Name 'REMOTE_STORAGE_ROOT' -Value $RemoteStorageRoot

if ([string]::IsNullOrWhiteSpace($JellyfinPublishedUrl)) {
    $JellyfinPublishedUrl = "https://$JellyfinDomain"
}

if (-not $EnableDlna.IsPresent -and $env:ENABLE_DLNA) {
    $EnableDlna = [switch](Get-BooleanValue -Value $env:ENABLE_DLNA)
}

if ([string]::IsNullOrWhiteSpace($QbittorrentUsername)) {
    $QbittorrentUsername = 'jellyfin'
}

if ([string]::IsNullOrWhiteSpace($QbittorrentPassword)) {
    $QbittorrentPassword = New-RandomSecret -Length 32
}

if ([string]::IsNullOrWhiteSpace($SudoPassword)) {
    if (-not [string]::IsNullOrWhiteSpace($SudoPasswordFile)) {
        if (-not (Test-Path $SudoPasswordFile)) {
            throw "Sudo password file not found: $SudoPasswordFile"
        }

        $SudoPassword = (Get-Content -Raw -Path $SudoPasswordFile).Trim()
    }
    else {
        $securePassword = Read-Host 'Enter the remote sudo password' -AsSecureString
        $SudoPassword = Get-PlainTextSecureString -SecureString $securePassword
    }
}

if ([string]::IsNullOrWhiteSpace($SudoPassword)) {
    throw 'A sudo password is required for remote deployment.'
}

if (-not (Test-Path $torrentSearchSource)) {
    throw "Torrent-Search-API source not found: $torrentSearchSource"
}

if (-not (Test-Path $buildScriptPath)) {
    throw "build_app.ps1 not found: $buildScriptPath"
}

$remoteFacts = Get-RemoteFacts -HostName $RemoteHost -User $RemoteUser -Port $RemotePort
$resolvedRemoteAppRoot = Resolve-RemotePath -Path $RemoteAppRoot -RemoteHome $remoteFacts.Home
$resolvedRemoteStorageRoot = Resolve-RemotePath -Path $RemoteStorageRoot -RemoteHome $remoteFacts.Home
$resolvedRemoteStorageLink = if ([string]::IsNullOrWhiteSpace($RemoteStorageLink)) { '' } else { Resolve-RemotePath -Path $RemoteStorageLink -RemoteHome $remoteFacts.Home }

Assert-NoWhitespacePath -Name 'REMOTE_APP_ROOT' -Value $resolvedRemoteAppRoot
Assert-NoWhitespacePath -Name 'REMOTE_STORAGE_ROOT' -Value $resolvedRemoteStorageRoot
if ($resolvedRemoteStorageLink) {
    Assert-NoWhitespacePath -Name 'REMOTE_STORAGE_LINK' -Value $resolvedRemoteStorageLink
}

$dockerPlatform = Get-DockerPlatform -Architecture $remoteFacts.Architecture
$imageName = 'custom-jellyfin'
$imageTag = '10.11.8-custom'
$customImage = "${imageName}:${imageTag}"

$pluginArtifact = $null
if (-not $SkipPlugin) {
    if (-not (Test-Path $pluginProjectPath)) {
        throw "Plugin project not found: $pluginProjectPath"
    }

    $pluginArtifact = Build-PluginArtifact -ProjectPath $pluginProjectPath
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("jellyfin-deploy-" + [Guid]::NewGuid().ToString('N'))
$stagingRoot = Join-Path $tempRoot 'stage'
$artifactRoot = Join-Path $stagingRoot 'artifacts'
$nginxRoot = Join-Path $stagingRoot 'nginx'
$scriptRoot = Join-Path $stagingRoot 'scripts'
$archivePath = Join-Path $tempRoot 'deployment.tar.gz'
$imageArchivePath = Join-Path $tempRoot 'custom-jellyfin.tar'
$remoteArchivePath = '/tmp/jellyfin-deployment.tar.gz'
$remoteImagePath = '/tmp/custom-jellyfin.tar'

New-Item -ItemType Directory -Path $artifactRoot -Force | Out-Null
New-Item -ItemType Directory -Path $nginxRoot -Force | Out-Null
New-Item -ItemType Directory -Path $scriptRoot -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $stagingRoot 'logs') -Force | Out-Null

Write-Host "Building the custom Jellyfin image archive for $dockerPlatform"
& $buildScriptPath -ImageName $imageName -ImageTag $imageTag -Platform $dockerPlatform -OutputTarPath $imageArchivePath
if ($LASTEXITCODE -ne 0) {
    throw 'Custom Jellyfin image build failed'
}

$composeExtraPorts = if ($EnableDlna) {
@'
    ports:
      - "7359:7359/udp"
      - "1900:1900/udp"
'@
}
else {
    ''
}

$tokens = @{
    '__CUSTOM_IMAGE__' = $customImage
    '__JELLYFIN_DOMAIN__' = $JellyfinDomain
    '__JELLYFIN_EXTRA_PORTS_BLOCK__' = $composeExtraPorts
    '__JELLYFIN_PUBLISHED_URL__' = $JellyfinPublishedUrl
    '__PUID__' = $remoteFacts.Uid.ToString()
    '__PGID__' = $remoteFacts.Gid.ToString()
    '__QBITTORRENT_PASSWORD__' = $QbittorrentPassword
    '__QBITTORRENT_TORRENT_PORT__' = $QbittorrentTorrentPort.ToString()
    '__QBITTORRENT_USERNAME__' = $QbittorrentUsername
    '__QBITTORRENT_WEBUI_PORT__' = $QbittorrentWebUiPort.ToString()
    '__REMOTE_STORAGE_ROOT__' = $resolvedRemoteStorageRoot
    '__TZ__' = $Timezone
}

$pluginTokens = $tokens.Clone()
$pluginTokens['__QBITTORRENT_USERNAME__'] = ConvertTo-XmlText -Value $QbittorrentUsername
$pluginTokens['__QBITTORRENT_PASSWORD__'] = ConvertTo-XmlText -Value $QbittorrentPassword

Set-AsciiLfContent -Path (Join-Path $stagingRoot 'docker-compose.yml') -Content (Expand-Template -TemplatePath (Join-Path $templateRoot 'remote-docker-compose.yml.tpl') -Tokens $tokens)
Set-AsciiLfContent -Path (Join-Path $nginxRoot 'http.conf') -Content (Expand-Template -TemplatePath (Join-Path $templateRoot 'nginx-http.conf.tpl') -Tokens $tokens)
Set-AsciiLfContent -Path (Join-Path $nginxRoot 'https.conf') -Content (Expand-Template -TemplatePath (Join-Path $templateRoot 'nginx-https.conf.tpl') -Tokens $tokens)
Set-AsciiLfContent -Path (Join-Path $scriptRoot 'bootstrap.sh') -Content (Get-Content -Raw -Path (Join-Path $templateRoot 'bootstrap.sh.tpl'))
Set-AsciiLfContent -Path (Join-Path $scriptRoot 'finalize-tls.sh') -Content (Get-Content -Raw -Path (Join-Path $templateRoot 'finalize-tls.sh.tpl'))
Set-AsciiLfContent -Path (Join-Path $scriptRoot 'renew-certificates.sh') -Content (Get-Content -Raw -Path (Join-Path $templateRoot 'renew-certificates.sh.tpl'))

if ($pluginArtifact) {
    Copy-Item -Path $pluginArtifact.DllPath -Destination (Join-Path $artifactRoot $pluginArtifact.FileName) -Force
    Set-AsciiLfContent -Path (Join-Path $artifactRoot 'MyJellyfinPlugin.xml') -Content (Expand-Template -TemplatePath (Join-Path $templateRoot 'plugin-config.xml.tpl') -Tokens $pluginTokens)
}

Copy-Item -Path $torrentSearchSource -Destination (Join-Path $stagingRoot 'Torrent-Search-API') -Recurse -Force

$deployEnvLines = @(
    "DEPLOY_SSH_USER=$(ConvertTo-ShellLiteral -Value $RemoteUser)"
    "JELLYFIN_DOMAIN=$(ConvertTo-ShellLiteral -Value $JellyfinDomain)"
    "LETSENCRYPT_EMAIL=$(ConvertTo-ShellLiteral -Value $LetsEncryptEmail)"
    "REMOTE_APP_ROOT=$(ConvertTo-ShellLiteral -Value $resolvedRemoteAppRoot)"
    "REMOTE_STORAGE_ROOT=$(ConvertTo-ShellLiteral -Value $resolvedRemoteStorageRoot)"
    "REMOTE_STORAGE_LINK=$(ConvertTo-ShellLiteral -Value $resolvedRemoteStorageLink)"
    "QBITTORRENT_USERNAME=$(ConvertTo-ShellLiteral -Value $QbittorrentUsername)"
    "QBITTORRENT_PASSWORD=$(ConvertTo-ShellLiteral -Value $QbittorrentPassword)"
    "QBITTORRENT_WEBUI_PORT=$(ConvertTo-ShellLiteral -Value $QbittorrentWebUiPort.ToString())"
    "QBITTORRENT_TORRENT_PORT=$(ConvertTo-ShellLiteral -Value $QbittorrentTorrentPort.ToString())"
    "QBITTORRENT_CATEGORY='jellyfin'"
    "PLUGIN_ENABLED=$(if ($pluginArtifact) { '1' } else { '0' })"
    "PLUGIN_DIRECTORY=$(ConvertTo-ShellLiteral -Value $(if ($pluginArtifact) { $pluginArtifact.DirectoryName } else { '' }))"
    "PLUGIN_DLL_NAME=$(ConvertTo-ShellLiteral -Value $(if ($pluginArtifact) { $pluginArtifact.FileName } else { 'MyJellyfinPlugin.dll' }))"
)

Set-AsciiLfContent -Path (Join-Path $stagingRoot 'deploy.env') -Content ($deployEnvLines -join "`n")

Push-Location $stagingRoot
try {
    Invoke-NativeCommand -FilePath 'tar' -Arguments @('-czf', $archivePath, '-C', $stagingRoot, '.') -ErrorMessage 'Failed to archive the deployment payload'
}
finally {
    Pop-Location
}

$scpArgsForArchive = @('-P', $RemotePort.ToString(), $archivePath, "${RemoteUser}@${RemoteHost}:${remoteArchivePath}")
$scpArgsForImage = @('-P', $RemotePort.ToString(), $imageArchivePath, "${RemoteUser}@${RemoteHost}:${remoteImagePath}")
Invoke-NativeCommand -FilePath 'scp' -Arguments $scpArgsForArchive -ErrorMessage 'Failed to upload the deployment payload'
Invoke-NativeCommand -FilePath 'scp' -Arguments $scpArgsForImage -ErrorMessage 'Failed to upload the Jellyfin image archive'

$remoteExtractCommand = "mkdir -p '$resolvedRemoteAppRoot' && rm -rf '$resolvedRemoteAppRoot/Torrent-Search-API' '$resolvedRemoteAppRoot/nginx' '$resolvedRemoteAppRoot/scripts' '$resolvedRemoteAppRoot/artifacts' '$resolvedRemoteAppRoot/logs' '$resolvedRemoteAppRoot/docker-compose.yml' '$resolvedRemoteAppRoot/deploy.env' && tar -xzf '$remoteArchivePath' -C '$resolvedRemoteAppRoot' && mv '$remoteImagePath' '$resolvedRemoteAppRoot/artifacts/custom-jellyfin.tar' && rm -f '$remoteArchivePath'"
Invoke-NativeCommand -FilePath 'ssh' -Arguments @('-p', $RemotePort.ToString(), "${RemoteUser}@${RemoteHost}", $remoteExtractCommand) -ErrorMessage 'Failed to unpack the deployment payload on the remote host'

$bootstrapCommand = "bash '$resolvedRemoteAppRoot/scripts/bootstrap.sh'"
Invoke-NativeCommand -FilePath 'ssh' -Arguments @('-p', $RemotePort.ToString(), "${RemoteUser}@${RemoteHost}", $bootstrapCommand) -StandardInput $SudoPassword -ErrorMessage 'Remote bootstrap failed'

$probeUrl = "http://$JellyfinDomain/__jellyfin_deploy_probe"
Write-Host "Waiting for the Cloudflare record to route $JellyfinDomain to this server"
Write-Host "Probe URL: $probeUrl"
Wait-ForProbe -Url $probeUrl -TimeoutSeconds $ProbeTimeoutSeconds

$finalizeCommand = "bash '$resolvedRemoteAppRoot/scripts/finalize-tls.sh'"
Invoke-NativeCommand -FilePath 'ssh' -Arguments @('-p', $RemotePort.ToString(), "${RemoteUser}@${RemoteHost}", $finalizeCommand) -StandardInput $SudoPassword -ErrorMessage 'TLS finalization failed'

Write-Host ''
Write-Host "Deployment complete."
Write-Host "Jellyfin URL: https://$JellyfinDomain"
Write-Host "Remote app root: $resolvedRemoteAppRoot"
Write-Host "Remote storage root: $resolvedRemoteStorageRoot"
if ($resolvedRemoteStorageLink) {
    Write-Host "Convenience symlink: $resolvedRemoteStorageLink -> $resolvedRemoteStorageRoot"
}
Write-Host "qBittorrent Web UI is bound to localhost:$QbittorrentWebUiPort on the target host."
Write-Host "qBittorrent credentials: $QbittorrentUsername / $QbittorrentPassword"
