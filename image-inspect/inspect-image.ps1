#requires -Version 7.4

Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'ActionRuntime.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'ImageReference.psm1') -Force

try {
    Write-ImageState
} catch {
    Write-GitHubAnnotation -Message $_.Exception.Message
    exit 1
}
