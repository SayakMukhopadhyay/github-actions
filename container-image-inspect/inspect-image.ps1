#requires -Version 7.4

Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'ActionRuntime.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'ContainerImage.psm1') -Force

try {
    Write-ContainerImageState
} catch {
    Write-GitHubAnnotation -Message $_.Exception.Message
    exit 1
}
