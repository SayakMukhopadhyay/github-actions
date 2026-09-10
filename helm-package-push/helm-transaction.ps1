#requires -Version 7.4

Import-Module (Join-Path $PSScriptRoot 'HelmTransaction.psm1') -Force

try {
    Invoke-HelmTransaction
} catch {
    Write-Output "::error::$($_.Exception.Message)"
    exit 1
}
