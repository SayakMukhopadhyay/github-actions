#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'ActionRuntime.psm1') -Force

function Get-CanonicalPath([string] $Path) {
    (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
}

function Assert-Contained([string] $Parent, [string] $Child, [string] $Label) {
    $relative = [IO.Path]::GetRelativePath($Parent, $Child)
    if ($relative -eq '..' -or $relative.StartsWith("..$([IO.Path]::DirectorySeparatorChar)")) {
        throw "$Label escapes the checkout"
    }
}

function Invoke-GitTransaction([ValidateSet('check-clean', 'commit')] [string] $Mode) {
    $workspaceValue = if ($env:GITHUB_WORKSPACE) {
        $env:GITHUB_WORKSPACE
    } else {
        (Get-Location).Path
    }

    $workspace = Get-CanonicalPath $workspaceValue
    Push-Location $workspace
    try {
        if ($Mode -eq 'check-clean') {
            if (Invoke-NativeProcess git @('status', '--porcelain')) {
                throw 'checkout is not clean before version mutation'
            }
            return
        }

        $helm = $env:INPUT_HELM -eq 'true'
        $go = $env:INPUT_GO -eq 'true'

        if (-not $helm -and -not $go) {
            Write-Output 'No version target was selected; nothing to do'
            return
        }

        $workingDirectory = if ($env:INPUT_WORKING_DIRECTORY) {
            $env:INPUT_WORKING_DIRECTORY
        } else {
            '.'
        }
        $project = Get-CanonicalPath (Join-Path $workspace $workingDirectory)
        Assert-Contained $workspace $project 'working-directory'
        $expected = [Collections.Generic.List[string]]::new()
        $versionPattern = '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

        if ($go) {
            if ($env:NEW_APPLICATION_VERSION -notmatch $versionPattern) {
                throw 'mutation did not produce a canonical application version'
            }
            $expected.Add([IO.Path]::GetRelativePath($workspace, (Join-Path $project 'VERSION')).Replace('\', '/'))
        }

        if ($helm) {
            if ($env:NEW_CHART_VERSION -notmatch $versionPattern) {
                throw 'mutation did not produce a canonical chart version'
            }
            $chartVersionPath = [IO.Path]::GetRelativePath(
                $workspace,
                (Join-Path $project 'charts/VERSION')
            ).Replace('\', '/')
            $chartMetadataPath = [IO.Path]::GetRelativePath(
                $workspace,
                (Join-Path $project 'charts/Chart.yaml')
            ).Replace('\', '/')

            $expected.Add($chartVersionPath)
            $expected.Add($chartMetadataPath)
        }

        foreach ($path in $expected) {
            $diff = Invoke-NativeProcess git @('diff', '--quiet', '--', $path) -RawOutput -AllowFailure
            if ($diff.ExitCode -eq 0) {
                throw "expected version file was not changed: $path"
            }
        }
        if (Invoke-NativeProcess git @('ls-files', '--others', '--exclude-standard')) {
            throw 'unexpected untracked files appeared during version mutation'
        }

        Invoke-NativeProcess git (@('add', '--') + $expected) | Out-Null
        if ((Invoke-NativeProcess git @('diff', '--quiet') -RawOutput -AllowFailure).ExitCode -ne 0) {
            throw 'unexpected unstaged changes appeared during version mutation'
        }

        $stagedResult = Invoke-NativeProcess git @('diff', '--cached', '--name-only', '-z') -RawOutput
        $staged = @($stagedResult.StandardOutput.Split([char] 0, [StringSplitOptions]::RemoveEmptyEntries))
        if ($staged.Count -ne $expected.Count -or @($staged | Where-Object { $_ -notin $expected }).Count) {
            throw 'version mutation staged unexpected files'
        }

        $message = if ($helm -and $go) {
            "feat: bump chart version to $env:NEW_CHART_VERSION and app version to $env:NEW_APPLICATION_VERSION"
        } elseif ($helm) {
            "feat: bump chart version to $env:NEW_CHART_VERSION"
        } else {
            "feat: bump app version to $env:NEW_APPLICATION_VERSION"
        }

        Invoke-NativeProcess git @('config', 'user.name', 'github-actions[bot]') | Out-Null
        $botEmail = '41898282+github-actions[bot]@users.noreply.github.com'
        Invoke-NativeProcess git @('config', 'user.email', $botEmail) | Out-Null
        Invoke-NativeProcess git @('-c', 'commit.gpgsign=false', 'commit', '-m', $message) | Out-Null

        Assert-SingleLine $env:TARGET_REF 'current branch' | Out-Null
        $branchArguments = @('check-ref-format', '--branch', $env:TARGET_REF)
        $validBranch = Invoke-NativeProcess git $branchArguments -RawOutput -AllowFailure
        if ($validBranch.ExitCode) {
            throw 'current branch is not a valid branch name'
        }

        Invoke-NativeProcess git @('push', 'origin', "HEAD:refs/heads/$env:TARGET_REF") | Out-Null
    } finally {
        Pop-Location
    }
}

Export-ModuleMember -Function Invoke-GitTransaction
