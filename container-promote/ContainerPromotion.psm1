#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'ActionRuntime.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'ContainerImage.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'RegistryCredentials.psm1') -Force

function Initialize-ContainerPromotion {
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
    $imageName = Resolve-ContainerImageName @coordinates
    $sourceReference = New-ContainerDigestReference -ImageName $imageName -Digest $env:INPUT_SOURCE_DIGEST
    $targetReference = New-ContainerTagReference -ImageName $imageName -Tag $env:INPUT_TAG

    Write-GitHubOutput 'source-reference' $sourceReference
    Write-GitHubOutput 'target-reference' $targetReference
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
