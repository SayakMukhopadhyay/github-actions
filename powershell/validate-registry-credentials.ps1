#requires -Version 7.4

Import-Module (Join-Path $PSScriptRoot 'RegistryCredentials.psm1') -Force

try {
    Assert-RegistryCredentials `
        -RegistryUser $env:INPUT_USERNAME `
        -RegistrySecret $env:INPUT_PASSWORD `
        -Requirement $env:REGISTRY_CREDENTIAL_REQUIREMENT
} catch {
    Write-Output "::error::$($_.Exception.Message)"
    exit 1
}
