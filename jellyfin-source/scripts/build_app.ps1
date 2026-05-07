param(
    [string]$ImageName = "custom-jellyfin",
    [string]$ImageTag = "10.11.8-custom",
    [string]$Platform,
    [string]$OutputTarPath
)

$ErrorActionPreference = "Stop"

$projectRoot = Split-Path $PSScriptRoot -Parent
$fullImage = "${ImageName}:${ImageTag}"

if (-not $OutputTarPath) {
    $OutputTarPath = Join-Path $PSScriptRoot "jellyfin.tar"
}

Write-Host "Project root: $projectRoot"
Write-Host "Docker image: $fullImage"

Push-Location $projectRoot
try {
    if (Test-Path $OutputTarPath) {
        Remove-Item $OutputTarPath -Force
    }

    if ([string]::IsNullOrWhiteSpace($Platform)) {
        Write-Host "Running local architecture build"
        docker build -t $fullImage .
        if ($LASTEXITCODE -ne 0) {
            throw "docker build failed"
        }

        Write-Host "Saving docker image archive"
        docker save -o $OutputTarPath $fullImage
        if ($LASTEXITCODE -ne 0) {
            throw "docker save failed"
        }
    }
    else {
        Write-Host "Running buildx build for platform $Platform"
        docker buildx version | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "docker buildx is required for cross-platform deployment builds"
        }

        docker buildx build --platform $Platform -t $fullImage --output "type=docker,dest=$OutputTarPath" .
        if ($LASTEXITCODE -ne 0) {
            throw "docker buildx build failed"
        }
    }

    if (-not (Test-Path $OutputTarPath)) {
        throw "Archive not created: $OutputTarPath"
    }
}
finally {
    Pop-Location
}

Write-Host "Build complete: $fullImage"
Write-Host "Created archive: $OutputTarPath"
