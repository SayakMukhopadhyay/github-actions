#requires -Version 7.4

Import-Module (Join-Path $PSScriptRoot 'GitTransaction.psm1') -Force

try {
    if (-not $args.Count) {
        throw 'transaction mode is required'
    }
    Invoke-GitTransaction -Mode $args[0]
} catch {
    Write-Output "::error::$($_.Exception.Message)"
    exit 1
}
