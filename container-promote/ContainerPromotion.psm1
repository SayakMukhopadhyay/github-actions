#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'ActionRuntime.psm1') -Force

function Initialize-ContainerPromotion {
    $digest = Assert-SingleLine $env:INPUT_SOURCE_DIGEST 'source-digest'
    $tag = Assert-SingleLine $env:INPUT_TAG tag
    $component = $env:INPUT_COMPONENT.ToLowerInvariant()
    $registry = $(if ($env:INPUT_REGISTRY) {
            $env:INPUT_REGISTRY
        } else {
            'ghcr.io'
        }).ToLowerInvariant()
    $repository = $(if ($env:INPUT_IMAGE_REPOSITORY) {
            $env:INPUT_IMAGE_REPOSITORY
        } else {
            $env:SOURCE_REPOSITORY
        }).ToLowerInvariant()

    foreach ($value in $component, $registry, $repository) {
        if ($value -match '[\x00-\x1f\x7f]') {
            throw 'Container image inputs must not contain control characters'
        }
    }

    $registryPattern = '^([a-z0-9]|[a-z0-9][a-z0-9-]*[a-z0-9])(\.([a-z0-9]|[a-z0-9][a-z0-9-]*[a-z0-9]))*(:[0-9]+)?$'
    $pathPattern = '^[a-z0-9]+(([._]|__|-+)[a-z0-9]+)*(/[a-z0-9]+(([._]|__|-+)[a-z0-9]+)*)*$'
    $coordinatesAreInvalid = (
        $registry -notmatch $registryPattern -or
        $repository -notmatch $pathPattern -or
        ($component -and $component -notmatch $pathPattern)
    )

    if ($coordinatesAreInvalid) {
        throw 'Invalid container image coordinates'
    }
    if ($digest -notmatch '^sha256:[0-9a-f]{64}$') {
        throw 'Invalid source image digest'
    }
    if ($tag -notmatch '^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$') {
        throw 'Invalid target container tag'
    }

    $imageName = "$registry/$repository"
    if ($component) {
        $imageName = "$imageName/$component"
    }
    Write-GitHubOutput 'source-reference' "$imageName@$digest"
    Write-GitHubOutput 'target-reference' "$imageName`:$tag"
}

function Invoke-ContainerPromotion {
    $arguments = @(
        'buildx',
        'imagetools',
        'create',
        '--prefer-index=false',
        '--tag',
        $env:TARGET_REFERENCE,
        $env:SOURCE_REFERENCE
    )
    Invoke-NativeProcess docker $arguments | Out-Null
}

Export-ModuleMember -Function Initialize-ContainerPromotion, Invoke-ContainerPromotion
