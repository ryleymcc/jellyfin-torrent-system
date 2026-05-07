$ErrorActionPreference = "Stop"

Write-Warning "send_deploy_app.ps1 now delegates to deploy-jellyfin.ps1. Set the universal deployment env vars before running it."

& "$PSScriptRoot\deploy-jellyfin.ps1" -SkipPlugin
