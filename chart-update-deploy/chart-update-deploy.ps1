#requires -Version 7.4

Import-Module (Join-Path $PSScriptRoot 'ChartUpdate.psm1') -Force

try {
    Invoke-ChartUpdate
} catch {
    Write-Output "::error::$($_.Exception.Message)"
    exit 1
}
