$ErrorActionPreference = "Stop"

$projectRoot = Split-Path $PSScriptRoot -Parent

$remoteUser = if ($env:DEPLOY_SSH_USER) { $env:DEPLOY_SSH_USER } else { throw "DEPLOY_SSH_USER is required." }
$remoteHost = if ($env:DEPLOY_SSH_HOST) { $env:DEPLOY_SSH_HOST } else { throw "DEPLOY_SSH_HOST is required." }
$remotePort = if ($env:DEPLOY_SSH_PORT) { [int]$env:DEPLOY_SSH_PORT } else { 22 }
$remoteSourceDir = if ($env:REMOTE_SOURCE_ROOT) { $env:REMOTE_SOURCE_ROOT } else { "~/jellyfin-app/jellyfin-source" }
$remoteSourceDirShell = if ($remoteSourceDir -eq "~") { '$HOME' } elseif ($remoteSourceDir.StartsWith("~/")) { '$HOME/' + $remoteSourceDir.Substring(2) } else { $remoteSourceDir }

$sourceArchive = Join-Path $PSScriptRoot "jellyfin-source.tar.gz"

Write-Host "Compressing source from $projectRoot"

if (Test-Path $sourceArchive) {
    Remove-Item $sourceArchive -Force
}

tar -czf $sourceArchive -C $projectRoot .
if ($LASTEXITCODE -ne 0) {
    throw "Source compression failed"
}

Write-Host "Checking remote space and permissions"
ssh -p $remotePort "${remoteUser}@${remoteHost}" "df -h ~ /tmp && ls -ld $remoteSourceDirShell /tmp 2>/dev/null || true"
if ($LASTEXITCODE -ne 0) {
    throw "Remote preflight failed"
}

Write-Host "Sending source archive"
scp -P $remotePort $sourceArchive "${remoteUser}@${remoteHost}:/tmp/jellyfin-source.tar.gz"
if ($LASTEXITCODE -ne 0) {
    throw "Source upload failed"
}

Write-Host "Extracting source on target host"
$remoteCmd = "mkdir -p $remoteSourceDirShell && rm -rf $remoteSourceDirShell/* && tar -xzf /tmp/jellyfin-source.tar.gz -C $remoteSourceDirShell && rm -f /tmp/jellyfin-source.tar.gz"
ssh -p $remotePort "${remoteUser}@${remoteHost}" $remoteCmd
if ($LASTEXITCODE -ne 0) {
    throw "Remote source extract failed"
}

Write-Host "Source sync complete"
