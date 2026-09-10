#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'ActionRuntime.psm1') -Force

function Initialize-ContainerBuild {
    $version = Assert-SingleLine $env:INPUT_VERSION version
    $component = $env:INPUT_COMPONENT
    $registry = if ($env:INPUT_REGISTRY) {
        $env:INPUT_REGISTRY
    } else {
        'ghcr.io'
    }
    $repository = if ($env:INPUT_IMAGE_REPOSITORY) {
        $env:INPUT_IMAGE_REPOSITORY
    } else {
        $env:SOURCE_REPOSITORY
    }

    foreach ($value in $component, $registry, $repository) {
        if ($value -match '[\x00-\x1f\x7f]') {
            throw 'Container image inputs must not contain control characters'
        }
    }

    $registry = $registry.ToLowerInvariant()
    $repository = $repository.ToLowerInvariant()
    $component = $component.ToLowerInvariant()
    $registryPattern = '^([a-z0-9]|[a-z0-9][a-z0-9-]*[a-z0-9])(\.([a-z0-9]|[a-z0-9][a-z0-9-]*[a-z0-9]))*(:[0-9]+)?$'
    $pathPattern = '^[a-z0-9]+(([._]|__|-+)[a-z0-9]+)*(/[a-z0-9]+(([._]|__|-+)[a-z0-9]+)*)*$'

    if ($registry -notmatch $registryPattern) {
        throw 'Invalid container registry'
    }
    if ($repository -notmatch $pathPattern) {
        throw 'Invalid image repository'
    }
    if ($component -and $component -notmatch $pathPattern) {
        throw 'Invalid image component'
    }
    if ($version -notmatch '^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$') {
        throw 'Invalid container version tag'
    }

    $imageName = "$registry/$repository"
    if ($component) {
        $imageName = "$imageName/$component"
    }
    Write-GitHubOutput 'image-reference' "$imageName`:$version"
    Write-GitHubOutput 'created' ([DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))
}

Export-ModuleMember -Function Initialize-ContainerBuild
