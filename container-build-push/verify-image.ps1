#requires -Version 7.4

Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'ActionRuntime.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ContainerPublicationVerification.psm1') -Force

try {
    Confirm-PublishedImageMetadata
} catch {
    Write-GitHubAnnotation -Message $_.Exception.Message
    exit 1
}
