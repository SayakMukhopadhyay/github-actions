#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-RegistryCredentials {
    [CmdletBinding()]
    param(
        [AllowEmptyString()] [string] $RegistryUser,
        [AllowEmptyString()] [string] $RegistrySecret,
        [Parameter(Mandatory)]
        [ValidateSet('Required', 'Optional', 'Forbidden')]
        [string] $Requirement
    )

    $usernameSupplied = -not [string]::IsNullOrEmpty($RegistryUser)
    $passwordSupplied = -not [string]::IsNullOrEmpty($RegistrySecret)

    if ($Requirement -eq 'Forbidden' -and ($usernameSupplied -or $passwordSupplied)) {
        throw 'Registry credentials cannot be used without a registry'
    }
    if ($Requirement -eq 'Required' -and (-not $usernameSupplied -or -not $passwordSupplied)) {
        throw 'Registry username and password are both required'
    }
    if ($Requirement -eq 'Optional' -and ($usernameSupplied -xor $passwordSupplied)) {
        throw 'Registry username and password must be provided together'
    }
}

Export-ModuleMember -Function Assert-RegistryCredentials
