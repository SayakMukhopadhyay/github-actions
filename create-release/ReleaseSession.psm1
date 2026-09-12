#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'ActionRuntime.psm1') -Force

function Invoke-CleanupReleaseSession {
    if (-not $env:SESSION_DIRECTORY) {
        return
    }

    if (-not $env:RUNNER_TEMP) {
        throw 'RUNNER_TEMP is required when a session exists'
    }
    $session = (Resolve-Path $env:SESSION_DIRECTORY).Path
    $root = (Resolve-Path $env:RUNNER_TEMP).Path

    $isOwnedSession = (
        [IO.Path]::GetDirectoryName($session) -eq $root -and
        [IO.Path]::GetFileName($session) -match '^create-release\.[A-Za-z0-9]+$'
    )

    if (-not $isOwnedSession) {
        throw 'session directory is not collector-owned'
    }

    Remove-ContainedTemporaryResource $session $root
}

Export-ModuleMember -Function 'Invoke-CleanupReleaseSession'
