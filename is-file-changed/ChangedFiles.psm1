#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'ActionRuntime.psm1')

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

function Invoke-ChangedFilesDiff([string]$Base, [string]$Head) {
    $diffArguments = @(
        'diff'
        '--name-status'
        '-z'
        '--find-renames'
        '--find-copies'
        '--find-copies-harder'
        $Base
        $Head
    )
    $result = Invoke-NativeProcess git $diffArguments -RawOutput -AllowFailure

    if ($result.ExitCode -ne 0) {
        throw "Git could not compare $Base and $Head"
    }

    $result.StandardOutput
}

function Resolve-RewriteMergeBase([string]$Base, [string]$Head, [string]$RequestedBase) {
    $mergeBaseArguments = @('merge-base', $Base, $Head)
    $mergeBase = Invoke-NativeProcess git $mergeBaseArguments -RawOutput -AllowFailure

    if ($mergeBase.ExitCode -eq 0 -and (Test-FullOid $mergeBase.StandardOutput.Trim())) {
        return $mergeBase.StandardOutput.Trim().ToLowerInvariant()
    }

    $shallow = Invoke-NativeProcess git @('rev-parse', '--is-shallow-repository') -RawOutput -AllowFailure
    if ($shallow.ExitCode -eq 0 -and $shallow.StandardOutput.Trim() -eq 'true') {
        foreach ($depth in 64, 1024) {
            $fetchArguments = @('fetch', '--no-tags', "--depth=$depth", 'origin', $RequestedBase)
            $fetch = Invoke-NativeProcess git $fetchArguments -RawOutput -AllowFailure

            if ($fetch.ExitCode -ne 0) {
                [Console]::Error.WriteLine(
                    "Merge-base history fetch at depth $depth failed for base ref $RequestedBase"
                )
                continue
            }

            $mergeBase = Invoke-NativeProcess git $mergeBaseArguments -RawOutput -AllowFailure
            if ($mergeBase.ExitCode -eq 0 -and (Test-FullOid $mergeBase.StandardOutput.Trim())) {
                return $mergeBase.StandardOutput.Trim().ToLowerInvariant()
            }
        }
    }

    throw "could not resolve a merge base for rewritten push endpoints $Base and $Head; " +
    'refusing to report an incomplete changed-path set'
}

function Invoke-ChangedFilesAction([ValidateSet('validate', 'collect')][string]$Mode = 'collect') {
    $baseRef = $env:BASE_REF
    $headRef = $env:HEAD_REF
    $isImplicitPush = -not ($baseRef -or $headRef)
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

        $changedFiles = Invoke-ChangedFilesDiff $base $head

        if ($isImplicitPush -and $baseRef -notmatch '^0+$') {
            $ancestor = Invoke-NativeProcess git @('merge-base', '--is-ancestor', $base, $head) `
                -RawOutput -AllowFailure

            if ($ancestor.ExitCode -eq 1) {
                $mergeBase = Resolve-RewriteMergeBase $base $head $baseRef
                $changedFiles += Invoke-ChangedFilesDiff $mergeBase $head
            } elseif ($ancestor.ExitCode -ne 0) {
                throw "Git could not determine whether push base $base is an ancestor of head $head"
            }
        }

        [System.IO.File]::WriteAllBytes($changedFile, [System.Text.Encoding]::UTF8.GetBytes($changedFiles))
        Write-GitHubOutput -Name 'changed-files' -Value $changedFile
    } finally {
        Pop-Location
    }
}

Export-ModuleMember -Function Invoke-ChangedFilesAction
