#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'ActionRuntime.psm1') -Force

function Test-FullOid([string]$Value) {
    $Value -match '^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$'
}

function Assert-ExplicitRef([string]$Value, [string]$Label) {
    if (Test-FullOid $Value) {
        if ($Value -match '^0+$') {
            throw "$Label-ref must not be a zero object ID"
        }
        return
    }
    $arguments = @('check-ref-format', '--branch', $Value)
    $result = Invoke-NativeProcess git $arguments -RawOutput -AllowFailure

    if ($result.ExitCode -ne 0) {
        throw "$Label-ref must be a full commit object ID or valid Git ref"
    }
}

function Resolve-Commit([string]$Requested, [string]$Label) {
    $resolveArguments = @('rev-parse', '--verify', '--quiet', "$Requested`^{commit}")
    $resolved = Invoke-NativeProcess git $resolveArguments -RawOutput -AllowFailure

    if ($resolved.ExitCode -eq 0 -and (Test-FullOid $resolved.StandardOutput.Trim())) {
        return $resolved.StandardOutput.Trim().ToLowerInvariant()
    }

    foreach ($attempt in 1..2) {
        $fetchArguments = @('fetch', '--no-tags', '--depth=1', 'origin', $Requested)
        $fetch = Invoke-NativeProcess git $fetchArguments -RawOutput -AllowFailure

        if ($fetch.ExitCode -eq 0) {
            $resolveArguments = @('rev-parse', '--verify', '--quiet', 'FETCH_HEAD^{commit}')
            $resolved = Invoke-NativeProcess git $resolveArguments -RawOutput -AllowFailure

            if ($resolved.ExitCode -eq 0 -and (Test-FullOid $resolved.StandardOutput.Trim())) {
                return $resolved.StandardOutput.Trim().ToLowerInvariant()
            }
        }

        [Console]::Error.WriteLine("Fetch attempt $attempt failed for $Label ref $Requested")
    }

    throw "could not resolve or fetch $Label ref $Requested as a commit after 2 attempts; " +
    'ensure the token can read the repository and the object exists'
}

function Invoke-ChangedFilesAction([ValidateSet('validate', 'collect')][string]$Mode = 'collect') {
    $baseRef = $env:BASE_REF
    $headRef = $env:HEAD_REF
    if ($baseRef -or $headRef) {
        if (-not $baseRef -or -not $headRef) {
            throw 'base-ref and head-ref must be provided together'
        }
        Assert-ExplicitRef $baseRef base
        Assert-ExplicitRef $headRef head
    } else {
        if ($env:EVENT_NAME -ne 'push') {
            throw 'is-file-changed requires a push event when base-ref and head-ref are omitted'
        }
        if (-not (Test-FullOid $env:BASE_SHA)) {
            throw 'push before SHA must be a full object ID'
        }
        if (-not (Test-FullOid $env:HEAD_SHA) -or $env:HEAD_SHA -match '^0+$') {
            throw 'push after SHA must be a non-zero full object ID'
        }
        $baseRef = $env:BASE_SHA
        $headRef = $env:HEAD_SHA
    }

    if ($Mode -eq 'validate') {
        return
    }

    $workspace = [System.IO.Path]::GetFullPath($(if ($env:GITHUB_WORKSPACE) {
                $env:GITHUB_WORKSPACE
            } else {
                (Get-Location).Path
            }))

    Push-Location $workspace
    try {
        $head = Resolve-Commit $headRef head
        $base = if ($baseRef -match '^0+$') {
            Invoke-NativeProcess git @('hash-object', '-t', 'tree', '--stdin') -StandardInput ''
        } else {
            Resolve-Commit $baseRef base
        }

        $temporaryRoot = if ($env:RUNNER_TEMP) {
            $env:RUNNER_TEMP
        } else {
            [System.IO.Path]::GetTempPath()
        }
        $changedFile = Join-Path $temporaryRoot "changed-paths-$([Guid]::NewGuid().ToString('N'))"

        $diffArguments = @(
            'diff'
            '--name-status'
            '-z'
            '--find-renames'
            '--find-copies'
            '--find-copies-harder'
            $base
            $head
        )
        $result = Invoke-NativeProcess git $diffArguments -RawOutput -AllowFailure

        if ($result.ExitCode -ne 0) {
            throw "Git could not compare $base and $head"
        }

        [System.IO.File]::WriteAllBytes($changedFile, [System.Text.Encoding]::UTF8.GetBytes($result.StandardOutput))
        Write-GitHubOutput -Name 'changed-files' -Value $changedFile
    } finally {
        Pop-Location
    }
}

Export-ModuleMember -Function Invoke-ChangedFilesAction
