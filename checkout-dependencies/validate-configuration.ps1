#requires -Version 7.4

Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'ActionRuntime.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'DependencyConfiguration.psm1') -Force

try {
    Test-DependencyConfiguration
} catch {
    Write-GitHubAnnotation -Message $_.Exception.Message
    exit 1
}
