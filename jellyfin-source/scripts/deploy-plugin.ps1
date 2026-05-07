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
