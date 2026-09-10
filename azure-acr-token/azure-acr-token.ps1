#requires -Version 7.4

Import-Module (Join-Path $PSScriptRoot 'AzureAcrToken.psm1') -Force

try {
    Invoke-AzureAcrTokenAction
} catch {
    Write-Output "::error::$($_.Exception.Message)"
    exit 1
}
