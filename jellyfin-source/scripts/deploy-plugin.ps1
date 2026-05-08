param(
    [string]$PluginProjectPath,
    [string]$Configuration = "Release",
    [string]$RemoteUser = $env:DEPLOY_SSH_USER,
    [string]$RemoteHost = $env:DEPLOY_SSH_HOST,
    [int]$RemotePort = $(if ($env:DEPLOY_SSH_PORT) { [int]$env:DEPLOY_SSH_PORT } else { 22 }),
    [string]$RemoteStorageRoot = $env:REMOTE_STORAGE_ROOT,
    [switch]$SkipRestart
)

$ErrorActionPreference = "Stop"

function Assert-CommandAvailable {
    param(
        [string]$CommandName,
        [string]$InstallHint
    )

    if (-not (Get-Command $CommandName -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace($InstallHint)) {
            throw "Missing required command: $CommandName"
        }

        throw "Missing required command: $CommandName. $InstallHint"
    }
}

function Invoke-NativeCapture {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$ErrorMessage = "Command failed"
    )

    $output = & $FilePath @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "$ErrorMessage`n$($output -join "`n")"
    }

    return ($output -join "`n").Trim()
}

function Assert-RemoteDockerAvailable {
    param(
        [string]$User,
        [string]$Host,
        [int]$Port
    )

    $remoteCommand = 'docker version >/dev/null 2>&1'
    Invoke-NativeCapture -FilePath 'ssh' -Arguments @('-p', $Port.ToString(), "${User}@${Host}", $remoteCommand) -ErrorMessage 'docker must already be installed on the target host before restarting Jellyfin.'
}

$workspaceRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

if (-not $PluginProjectPath) {
    $PluginProjectPath = Join-Path $workspaceRoot "MyJellyfinPlugin\MyJellyfinPlugin.csproj"
}

if ([string]::IsNullOrWhiteSpace($RemoteUser) -or [string]::IsNullOrWhiteSpace($RemoteHost)) {
    throw "DEPLOY_SSH_USER and DEPLOY_SSH_HOST are required."
}

if ([string]::IsNullOrWhiteSpace($RemoteStorageRoot)) {
    throw "REMOTE_STORAGE_ROOT is required."
}

Assert-CommandAvailable -CommandName 'dotnet' -InstallHint 'Install the .NET 9 SDK on the deploy machine before deploying the plugin.'
Assert-CommandAvailable -CommandName 'ssh' -InstallHint 'Install the OpenSSH client on the deploy machine.'
Assert-CommandAvailable -CommandName 'scp' -InstallHint 'Install the OpenSSH client on the deploy machine.'

if (-not $SkipRestart) {
    Assert-RemoteDockerAvailable -User $RemoteUser -Host $RemoteHost -Port $RemotePort
}

$resolvedProjectPath = (Resolve-Path $PluginProjectPath).Path
$pluginRoot = Split-Path $resolvedProjectPath -Parent
$pluginName = [System.IO.Path]::GetFileNameWithoutExtension($resolvedProjectPath)
$remote = "${RemoteUser}@${RemoteHost}"
$remotePluginBaseDir = "$RemoteStorageRoot/jellyfin/config/data/plugins"

Write-Host "Building plugin project: $resolvedProjectPath"
dotnet build $resolvedProjectPath -c $Configuration
if ($LASTEXITCODE -ne 0) {
    throw "Plugin build failed"
}

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

$remotePluginDir = "$remotePluginBaseDir/${pluginName}_${pluginVersion}"

Write-Host "Ensuring remote plugin directory exists: $remotePluginDir"
ssh -p $RemotePort $remote "mkdir -p '$remotePluginDir'"
if ($LASTEXITCODE -ne 0) {
    throw "Remote plugin directory creation failed"
}

Write-Host "Uploading plugin assembly: $dllPath"
scp -P $RemotePort $dllPath "${remote}:$remotePluginDir/"
if ($LASTEXITCODE -ne 0) {
    throw "Plugin upload failed"
}

if (-not $SkipRestart) {
    Write-Host "Restarting Jellyfin container"
    ssh -p $RemotePort $remote "docker restart jellyfin"
    if ($LASTEXITCODE -ne 0) {
        throw "jellyfin restart failed"
    }
}

Write-Host "Plugin deployed to ${remotePluginDir}"
