#requires -Version 7.4

Import-Module (Join-Path $PSScriptRoot 'ContainerBuild.psm1') -Force

try {
    Get-ContainerArtifactState
} catch {
    Write-Output "::error::$($_.Exception.Message)"
    exit 1
}
