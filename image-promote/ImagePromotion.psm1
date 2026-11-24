#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'ActionRuntime.psm1')
Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'ImageReference.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'RegistryCredentials.psm1') -Force

function Initialize-ImagePromotion {
    Assert-RegistryCredentials `
        -RegistryUser $env:INPUT_USERNAME `
        -RegistrySecret $env:INPUT_PASSWORD `
        -Requirement Required

    $coordinates = @{
        Component        = $env:INPUT_COMPONENT
        Registry         = $env:INPUT_REGISTRY
        ImageRepository  = $env:INPUT_IMAGE_REPOSITORY
        SourceRepository = $env:SOURCE_REPOSITORY
    }
    $imageName = Resolve-ImageName @coordinates
    $sourceReference = New-ImageDigestReference -ImageName $imageName -Digest $env:INPUT_SOURCE_DIGEST
    $targetReference = New-ImageTagReference -ImageName $imageName -Tag $env:INPUT_TAG

    Write-GitHubOutput 'source-reference' $sourceReference
    Write-GitHubOutput 'target-reference' $targetReference
}

function Invoke-ImagePromotion {
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

Export-ModuleMember -Function Initialize-ImagePromotion, Invoke-ImagePromotion
