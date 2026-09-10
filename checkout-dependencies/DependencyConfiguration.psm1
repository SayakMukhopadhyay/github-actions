#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-DependencyConfiguration {
    if ($env:INPUT_NODE_VERSION -and $env:INPUT_NODE_VERSION_FILE) {
        throw 'node-version and node-version-file are mutually exclusive; provide exactly one to enable Node.js.'
    }

    if (-not $env:INPUT_GO_VERSION -and -not $env:INPUT_NODE_VERSION -and -not $env:INPUT_NODE_VERSION_FILE) {
        throw 'configure at least one ecosystem with go-version, node-version, or node-version-file.'
    }
}

Export-ModuleMember -Function Test-DependencyConfiguration
