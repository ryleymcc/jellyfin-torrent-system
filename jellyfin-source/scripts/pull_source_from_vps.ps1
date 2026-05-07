$ErrorActionPreference = "Stop"

$remoteUser = if ($env:DEPLOY_SSH_USER) { $env:DEPLOY_SSH_USER } else { throw "DEPLOY_SSH_USER is required." }
$remoteHost = if ($env:DEPLOY_SSH_HOST) { $env:DEPLOY_SSH_HOST } else { throw "DEPLOY_SSH_HOST is required." }
$remotePort = if ($env:DEPLOY_SSH_PORT) { [int]$env:DEPLOY_SSH_PORT } else { 22 }
$remoteSourceDir = if ($env:REMOTE_SOURCE_ROOT) { $env:REMOTE_SOURCE_ROOT } else { "~/jellyfin-app/jellyfin-source" }
$remoteSourceDirShell = if ($remoteSourceDir -eq "~") { '$HOME' } elseif ($remoteSourceDir.StartsWith("~/")) { '$HOME/' + $remoteSourceDir.Substring(2) } else { $remoteSourceDir }

$projectRoot = Split-Path $PSScriptRoot -Parent
$remote = "${remoteUser}@${remoteHost}"

Write-Host "Pulling source from target host: $remoteSourceDir"
Write-Host "Extracting into: $projectRoot"

$tarPipeline = 'ssh -p {0} -T {1} "tar -czf - -C {2} ." | tar -xzf - -C "{3}"' -f $remotePort, $remote, $remoteSourceDirShell, $projectRoot

cmd /c $tarPipeline
$tarExitCode = $LASTEXITCODE

if ($tarExitCode -ne 0) {
    Write-Warning "Tar stream pull failed (exit code $tarExitCode). Falling back to recursive scp."

    scp -P $remotePort -r "${remote}:$remoteSourceDirShell/." "$projectRoot"
    if ($LASTEXITCODE -ne 0) {
        throw "Source pull failed"
    }
}

Write-Host "Source pulled successfully"
