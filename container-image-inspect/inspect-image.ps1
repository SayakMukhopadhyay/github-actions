#requires -Version 7.4

Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'ContainerImage.psm1') -Force

try {
    Write-ContainerImageState
} catch {
    Write-Output "::error::$($_.Exception.Message)"
    exit 1
}
