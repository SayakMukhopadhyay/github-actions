#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'ActionRuntime.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'ContainerImage.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'RegistryCredentials.psm1') -Force

function Initialize-ContainerImageInspection {
    Assert-RegistryCredentials `
        -RegistryUser $env:INPUT_USERNAME `
        -RegistrySecret $env:INPUT_PASSWORD `
        -Requirement Optional

    $imageReference = Resolve-ContainerImageReference `
        -Version $env:INPUT_VERSION `
        -Component $env:INPUT_COMPONENT `
        -Registry $env:INPUT_REGISTRY `
        -ImageRepository $env:INPUT_IMAGE_REPOSITORY `
        -SourceRepository $env:SOURCE_REPOSITORY

    Write-GitHubOutput 'image-reference' $imageReference
}

Export-ModuleMember -Function Initialize-ContainerImageInspection
