#requires -Version 7.4

Import-Module (Join-Path $PSScriptRoot 'CreateRelease.psm1') -Force

try {
    Invoke-CollectReleaseContext
} catch {
    [Console]::Error.WriteLine("create-release: $($_.Exception.Message)")
    exit 1
}
