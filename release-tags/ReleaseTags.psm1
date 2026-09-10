#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'ActionRuntime.psm1') -Force

function Invoke-ReleaseTags {
    $mode = if ($env:INPUT_MODE) {
        $env:INPUT_MODE
    } else {
        'verify'
    }

    if ($mode -notin 'exists', 'verify', 'ensure') {
        throw 'mode must be exists, verify, or ensure'
    }
    $token = Assert-SingleLine $env:INPUT_TOKEN token
    $targetSha = Assert-SingleLine $env:TARGET_SHA 'github.sha'

    if (-not $env:GITHUB_OUTPUT) {
        throw 'GITHUB_OUTPUT is required'
    }

    $tags = @($env:INPUT_TAGS -split "`n" | ForEach-Object { $_.TrimEnd("`r") })
    if (-not $tags.Count -or $tags -contains '') {
        throw 'tags contains an empty line'
    }
    if ($tags.Count -gt 256) {
        throw 'tags exceeds the limit of 256'
    }
    if (@($tags | Select-Object -Unique).Count -ne $tags.Count) {
        throw 'duplicate tag'
    }
    foreach ($tag in $tags) {
        if ($tag.Length -gt 255) {
            throw "tag name exceeds the supported length: $tag"
        }
        $validTag = Invoke-NativeProcess git @('check-ref-format', "refs/tags/$tag") -RawOutput -AllowFailure
        if ($validTag.ExitCode) {
            throw "invalid Git tag name: $tag"
        }
    }

    $workspaceValue = if ($env:GITHUB_WORKSPACE) {
        $env:GITHUB_WORKSPACE
    } else {
        (Get-Location).Path
    }
    $workspace = (Resolve-Path $workspaceValue).Path
    Push-Location $workspace
    try {
        $target = (Invoke-NativeProcess git @('rev-parse', '--verify', "$targetSha`^{commit}")).ToLowerInvariant()
        if ((Invoke-NativeProcess git @('rev-parse', 'HEAD')).ToLowerInvariant() -ne $target) {
            throw 'checkout HEAD does not match github.sha'
        }

        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("x-access-token:$token"))
        $overlay = @{
            GIT_CONFIG_COUNT    = '2'
            GIT_CONFIG_KEY_0    = 'credential.helper'
            GIT_CONFIG_VALUE_0  = ''
            GIT_CONFIG_KEY_1    = 'http.extraheader'
            GIT_CONFIG_VALUE_1  = "AUTHORIZATION: basic $encoded"
            GIT_TERMINAL_PROMPT = '0'
            INPUT_TOKEN         = $null
        }

        function Read-TagState {
            $patterns = @()
            foreach ($tag in $tags) {
                $patterns += "refs/tags/$tag"
                $patterns += "refs/tags/$tag^{}"
            }

            $arguments = @('ls-remote', 'origin') + $patterns
            $result = Invoke-NativeProcess git $arguments -Environment $overlay -RawOutput -AllowFailure
            if ($result.ExitCode) {
                throw 'could not read release tags from origin'
            }

            $direct = @{}
            $peeled = @{}
            foreach ($line in $result.StandardOutput -split "`r?`n" | Where-Object { $_ }) {
                $parts = $line -split "`t"
                if ($parts.Count -ne 2 -or $parts[0] -notmatch '^[0-9a-fA-F]{40,64}$') {
                    throw 'origin returned an invalid tag object ID'
                }
                $ref = $parts[1]
                $isPeeled = $ref.EndsWith('^{}')
                $name = ($ref -replace '\^\{\}$', '') -replace '^refs/tags/', ''

                if ($name -notin $tags) {
                    throw 'origin returned an unexpected tag ref'
                }
                if ($isPeeled) {
                    $peeled[$name] = $parts[0].ToLowerInvariant()
                } else {
                    $direct[$name] = $parts[0].ToLowerInvariant()
                }
            }

            $missing = @()
            $conflicting = @()
            foreach ($tag in $tags) {
                $resolved = if ($peeled.ContainsKey($tag)) {
                    $peeled[$tag]
                } elseif ($direct.ContainsKey($tag)) {
                    $direct[$tag]
                } else {
                    $null
                }

                if (-not $resolved) {
                    $missing += $tag
                } elseif ($resolved -ne $target) {
                    $conflicting += $tag
                }
            }
            @{ Missing = $missing; Conflicting = $conflicting }
        }

        $state = Read-TagState
        if ($mode -eq 'exists') {
            Write-GitHubOutput 'tags-exist' $(if (-not $state.Missing.Count) {
                    'true'
                } else {
                    'false'
                })
            return
        }

        if ($mode -eq 'verify') {
            $matches = -not $state.Missing.Count -and -not $state.Conflicting.Count
            Write-GitHubOutput 'tags-match' $(if ($matches) {
                    'true'
                } else {
                    'false'
                })
            return
        }

        if ($state.Conflicting.Count) {
            throw "refusing to overwrite tags resolving to another object: $($state.Conflicting -join ' ')"
        }
        if (-not $state.Missing.Count) {
            Write-GitHubOutput 'tags-match' 'true'
            return
        }


        $refspecs = @($state.Missing | ForEach-Object { "$target`:refs/tags/$_" })
        $arguments = @('push', '--atomic', '--no-force', 'origin') + $refspecs
        $push = Invoke-NativeProcess git $arguments -Environment $overlay -RawOutput -AllowFailure
        $state = Read-TagState

        if (-not $state.Missing.Count -and -not $state.Conflicting.Count) {
            Write-GitHubOutput 'tags-match' 'true'
            return
        }

        if ($push.ExitCode) {
            throw 'atomic tag push was rejected and the requested tags do not all resolve to github.sha'
        }
        throw 'origin did not retain the requested tag set after a successful atomic push'
    } finally {
        Pop-Location
    }
}

Export-ModuleMember -Function Invoke-ReleaseTags
