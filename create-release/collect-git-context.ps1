#requires -Version 7.4

Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'ActionRuntime.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CreateRelease.psm1') -Force

try {
    Invoke-CollectReleaseContext
} catch {
    Write-GitHubAnnotation -Message "create-release: $($_.Exception.Message)"
    exit 1
}
