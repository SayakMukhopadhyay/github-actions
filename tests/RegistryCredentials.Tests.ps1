#requires -Version 7.4

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'RegistryCredentials.psm1') -Force
}

Describe 'Registry credential policy matrix' {
    It '<Name>' -ForEach @(
        @{ Name = 'requires both credentials for container build push'; Requirement = 'Required'; AllowNone = $false; AllowPair = $true }
        @{ Name = 'allows neither or both credentials for container build without push'; Requirement = 'Optional'; AllowNone = $true; AllowPair = $true }
        @{ Name = 'requires both credentials for Helm package push'; Requirement = 'Required'; AllowNone = $false; AllowPair = $true }
        @{ Name = 'allows neither or both credentials for Helm package without push'; Requirement = 'Optional'; AllowNone = $true; AllowPair = $true }
        @{ Name = 'allows neither or both credentials for container inspection'; Requirement = 'Optional'; AllowNone = $true; AllowPair = $true }
        @{ Name = 'requires both credentials for container promotion'; Requirement = 'Required'; AllowNone = $false; AllowPair = $true }
        @{ Name = 'requires both credentials for chart update with a registry'; Requirement = 'Required'; AllowNone = $false; AllowPair = $true }
        @{ Name = 'forbids credentials for chart update without a registry'; Requirement = 'Forbidden'; AllowNone = $true; AllowPair = $false }
    ) {
        if ($AllowNone) {
            { Assert-RegistryCredentials -RegistryUser '' -RegistrySecret '' -Requirement $Requirement } |
                Should -Not -Throw
        } else {
            { Assert-RegistryCredentials -RegistryUser '' -RegistrySecret '' -Requirement $Requirement } |
                Should -Throw
        }

        if ($AllowPair) {
            { Assert-RegistryCredentials -RegistryUser user -RegistrySecret token -Requirement $Requirement } |
                Should -Not -Throw
        } else {
            { Assert-RegistryCredentials -RegistryUser user -RegistrySecret token -Requirement $Requirement } |
                Should -Throw
        }

        { Assert-RegistryCredentials -RegistryUser user -RegistrySecret '' -Requirement $Requirement } |
            Should -Throw
        { Assert-RegistryCredentials -RegistryUser '' -RegistrySecret token -Requirement $Requirement } |
            Should -Throw
    }
}
