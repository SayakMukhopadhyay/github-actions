#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'ActionRuntime.psm1')
Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'ContainerImage.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'RegistryCredentials.psm1') -Force

function Initialize-ContainerBuild {
    $credentialRequirement = if ($env:INPUT_PUSH -eq 'true') {
        'Required'
    } else {
        'Optional'
    }
    Assert-RegistryCredentials `
        -RegistryUser $env:INPUT_USERNAME `
        -RegistrySecret $env:INPUT_PASSWORD `
        -Requirement $credentialRequirement

    $imageReference = Resolve-ContainerImageReference `
        -Version $env:INPUT_VERSION `
        -Component $env:INPUT_COMPONENT `
        -Registry $env:INPUT_REGISTRY `
        -ImageRepository $env:INPUT_IMAGE_REPOSITORY `
        -SourceRepository $env:SOURCE_REPOSITORY

    $created = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $labels = @(
        "org.opencontainers.image.created=$created"
        "org.opencontainers.image.version=$($env:INPUT_VERSION)"
        "org.opencontainers.image.revision=$($env:SOURCE_REVISION)"
        "org.opencontainers.image.source=$($env:SOURCE_URL)"
    ) -join "`n"
    $temporaryIdentity = @(
        $env:GITHUB_RUN_ID
        $env:GITHUB_RUN_ATTEMPT
        $env:GITHUB_ACTION
        $imageReference
    ) -join "`0"
    $temporaryHash = [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($temporaryIdentity))
    ).ToLowerInvariant().Substring(0, 24)

    Write-GitHubOutput 'image-reference' $imageReference
    Write-GitHubOutput 'inspection-reference' "container-build-push-inspection:$temporaryHash"
    Write-GitHubOutput 'labels' $labels
}

Export-ModuleMember -Function 'Initialize-ContainerBuild'
