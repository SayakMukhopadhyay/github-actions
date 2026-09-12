#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'ActionRuntime.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'ContainerImage.psm1') -Force

function Initialize-ContainerImageInspection {
    $usernameSupplied = -not [string]::IsNullOrEmpty($env:INPUT_USERNAME)
    $passwordSupplied = -not [string]::IsNullOrEmpty($env:INPUT_PASSWORD)
    if ($usernameSupplied -xor $passwordSupplied) {
        throw 'Registry username and password must be provided together'
    }

    $imageReference = Resolve-ContainerImageReference `
        -Version $env:INPUT_VERSION `
        -Component $env:INPUT_COMPONENT `
        -Registry $env:INPUT_REGISTRY `
        -ImageRepository $env:INPUT_IMAGE_REPOSITORY `
        -SourceRepository $env:SOURCE_REPOSITORY

    Write-GitHubOutput 'image-reference' $imageReference
}

Export-ModuleMember -Function Initialize-ContainerImageInspection
