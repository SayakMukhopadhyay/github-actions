#requires -Version 7.4

Import-Module (Join-Path $PSScriptRoot 'StaticSiteUpdate.psm1') -Force

try {
    Invoke-StaticSiteUpdate
} catch {
    Write-Output "::error::$($_.Exception.Message)"
    exit 1
}
