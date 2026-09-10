#requires -Version 7.4

Import-Module (Join-Path $PSScriptRoot 'ReleaseTags.psm1') -Force

try {
    Invoke-ReleaseTags
} catch {
    [Console]::Error.WriteLine("release-tags: $($_.Exception.Message)")
    exit 1
}
