#requires -Version 7.4

Import-Module (Join-Path $PSScriptRoot 'ActionRuntime.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'RegistryCredentials.psm1') -Force

try {
    Assert-RegistryCredentials `
        -RegistryUser $env:INPUT_USERNAME `
        -RegistrySecret $env:INPUT_PASSWORD `
        -Requirement $env:REGISTRY_CREDENTIAL_REQUIREMENT
} catch {
    Write-GitHubAnnotation -Message $_.Exception.Message
    exit 1
}
