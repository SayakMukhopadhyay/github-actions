#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'ActionRuntime.psm1')
Import-Module (Join-Path $PSScriptRoot 'OciArtifactProbe.psm1')

function Resolve-ImageName {
    [CmdletBinding()]
    param(
        [AllowEmptyString()] [string] $Component,
        [AllowEmptyString()] [string] $Registry,
        [AllowEmptyString()] [string] $ImageRepository,
        [AllowEmptyString()] [string] $SourceRepository
    )

    $component = $Component
    $registry = if ($Registry) {
        $Registry
    } else {
        'ghcr.io'
    }
    $repository = if ($ImageRepository) {
        $ImageRepository
    } else {
        $SourceRepository
    }

    foreach ($value in $component, $registry, $repository) {
        if ($value -match '[\x00-\x1f\x7f]') {
            throw 'Image inputs must not contain control characters'
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

    $imageName = "$registry/$repository"
    if ($component) {
        $imageName = "$imageName/$component"
    }
    $imageName
}

function New-ImageTagReference {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ImageName,
        [AllowEmptyString()] [string] $Tag
    )

    $tag = Assert-SingleLine $Tag tag
    if ($tag -notmatch '^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$') {
        throw 'Invalid image tag'
    }
    '{0}:{1}' -f $ImageName, $tag
}

function New-ImageDigestReference {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ImageName,
        [AllowEmptyString()] [string] $Digest
    )

    $digest = Assert-SingleLine $Digest digest
    if ($digest -notmatch '^sha256:[0-9a-f]{64}$') {
        throw 'Invalid image digest'
    }
    '{0}@{1}' -f $ImageName, $digest
}

function Resolve-ImageReference {
    [CmdletBinding()]
    param(
        [AllowEmptyString()] [string] $Tag,
        [AllowEmptyString()] [string] $Component,
        [AllowEmptyString()] [string] $Registry,
        [AllowEmptyString()] [string] $ImageRepository,
        [AllowEmptyString()] [string] $SourceRepository
    )

    $coordinates = @{
        Component        = $Component
        Registry         = $Registry
        ImageRepository  = $ImageRepository
        SourceRepository = $SourceRepository
    }
    $imageName = Resolve-ImageName @coordinates
    New-ImageTagReference -ImageName $imageName -Tag $Tag
}

function Write-ImageState {
    $imageReference = Assert-SingleLine $env:IMAGE_REFERENCE 'image-reference'
    $probe = Invoke-OciArtifactProbe docker @(
        'buildx'
        'imagetools'
        'inspect'
        '--format'
        '{{json .Manifest}}'
        $imageReference
    )

    if (-not $probe.Exists) {
        Write-GitHubOutput 'exists' 'false'
        Write-GitHubOutput 'image-digest' ''
        return
    }

    try {
        $manifest = $probe.StandardOutput | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw 'Docker returned invalid manifest JSON for the existing image reference'
    }
    if ($manifest.digest -notmatch '^sha256:[0-9a-f]{64}$') {
        throw 'Docker did not return a valid manifest digest for the existing image reference'
    }

    Write-GitHubOutput 'exists' 'true'
    Write-GitHubOutput 'image-digest' $manifest.digest
}

Export-ModuleMember -Function @(
    'Resolve-ImageName'
    'New-ImageTagReference'
    'New-ImageDigestReference'
    'Resolve-ImageReference'
    'Write-ImageState'
)
