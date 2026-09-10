#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'ActionRuntime.psm1') -Force

function Assert-ContainedPath {
    param(
        [Parameter(Mandatory)] [string] $Parent,
        [Parameter(Mandatory)] [string] $Child,
        [Parameter(Mandatory)] [string] $Label
    )

    $relative = [IO.Path]::GetRelativePath($Parent, $Child)
    if ($relative -eq '..' -or $relative.StartsWith("..$([IO.Path]::DirectorySeparatorChar)")) {
        throw "$Label escapes its containing directory"
    }
}

function Invoke-ChartUpdate {
    $workspaceInput = if ($env:GITHUB_WORKSPACE) {
        $env:GITHUB_WORKSPACE
    } else {
        (Get-Location).Path
    }
    $workspace = (Resolve-Path $workspaceInput).Path
    $checkoutInput = if ($env:INPUT_CHECKOUT_PATH) {
        $env:INPUT_CHECKOUT_PATH
    } else {
        '.gitops-charts'
    }
    $checkout = (Resolve-Path (Join-Path $workspace $checkoutInput)).Path
    Assert-ContainedPath -Parent $workspace -Child $checkout -Label 'target checkout'

    if (Invoke-NativeProcess git @('-C', $checkout, 'status', '--porcelain')) {
        throw 'target repository checkout is not clean'
    }
    if ((Invoke-NativeProcess yq @('--version')) -notmatch 'version\s+v?4\.') {
        throw 'yq v4 is required'
    }

    $environment = Assert-SingleLine $env:INPUT_ENVIRONMENT environment
    $chartName = Assert-SingleLine $env:INPUT_CHART_NAME 'chart-name'
    $dependency = if ($env:INPUT_DEPENDENCY) {
        $env:INPUT_DEPENDENCY
    } else {
        $chartName
    }
    $version = $env:INPUT_CHART_VERSION
    $image = $env:INPUT_IMAGE_TAG
    $targetRef = if ($env:INPUT_TARGET_REF) {
        $env:INPUT_TARGET_REF
    } else {
        'main'
    }

    if (-not $version -and -not $image) {
        throw 'at least one of chart-version or image-tag is required'
    }
    if ($version -and $version -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?$') {
        throw 'chart-version must be an exact semantic version'
    }
    if ($image -and $image -notmatch '^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$') {
        throw 'image-tag must be a valid container image tag'
    }
    if ($dependency.Contains('/') -or $dependency.Contains("`n") -or $dependency.Contains("`r")) {
        throw 'dependency must be a chart name or alias'
    }

    $refCheck = Invoke-NativeProcess git @('check-ref-format', '--branch', $targetRef) -RawOutput -AllowFailure
    if ($refCheck.ExitCode) {
        throw 'target-ref must be a valid branch name'
    }

    $wrapperRelative = if ($env:INPUT_WRAPPER_CHART_PATH) {
        $env:INPUT_WRAPPER_CHART_PATH
    } else {
        "$chartName/envs/$environment"
    }
    $wrapper = (Resolve-Path (Join-Path $checkout $wrapperRelative)).Path
    Assert-ContainedPath -Parent $checkout -Child $wrapper -Label 'wrapper-chart-path'

    Invoke-NativeProcess git @('-C', $checkout, 'config', 'user.name', 'github-actions[bot]') | Out-Null
    $botEmail = '41898282+github-actions[bot]@users.noreply.github.com'
    Invoke-NativeProcess git @('-C', $checkout, 'config', 'user.email', $botEmail) | Out-Null

    $state = @{
        Changed        = @()
        DependencyName = $null
        Archives       = $null
        Protected      = @()
    }

    function Invoke-WrapperMutation {
        $chartFile = (Resolve-Path (Join-Path $wrapper 'Chart.yaml')).Path
        $lockFile = Join-Path $wrapper 'Chart.lock'
        $queryEnvironment = @{ REQUESTED_DEPENDENCY = $dependency }
        $dependencyQuery = (
            '.dependencies[] | ' +
            'select(.name == strenv(REQUESTED_DEPENDENCY) or .alias == strenv(REQUESTED_DEPENDENCY))'
        )

        $count = Invoke-NativeProcess yq @(
            '-er'
            "[$dependencyQuery] | length"
            $chartFile
        ) -Environment $queryEnvironment
        if ($count -ne '1') {
            throw "$chartFile must contain exactly one dependency matching '$dependency'; found $count"
        }

        $dependencyName = Invoke-NativeProcess yq @(
            '-er'
            "$dependencyQuery | .name"
            $chartFile
        ) -Environment $queryEnvironment
        $alias = Invoke-NativeProcess yq @(
            '-er'
            "$dependencyQuery | .alias // `"`""
            $chartFile
        ) -Environment $queryEnvironment
        foreach ($coordinate in $dependencyName, $alias) {
            if ($coordinate.Contains('/') -or $coordinate.Contains("`n") -or $coordinate.Contains("`r")) {
                throw 'selected dependency name or alias is invalid'
            }
        }
        if ([string]::IsNullOrWhiteSpace($dependencyName)) {
            throw 'selected dependency name or alias is invalid'
        }

        $valuesRoot = if ($alias) {
            $alias
        } else {
            $dependencyName
        }
        $chartRelative = [IO.Path]::GetRelativePath($checkout, $chartFile).Replace('\', '/')
        $state.DependencyName = $dependencyName
        $state.Archives = [IO.Path]::GetRelativePath($checkout, (Join-Path $wrapper 'charts')).Replace('\', '/')
        $state.Protected = @()

        if ($version) {
            $lockRelative = [IO.Path]::GetRelativePath($checkout, $lockFile).Replace('\', '/')
            $state.Protected += $chartRelative, $lockRelative
            $targetArchive = Join-Path $wrapper "charts/$dependencyName-$version.tgz"
            $currentVersion = Invoke-NativeProcess yq @(
                '-er'
                "$dependencyQuery | .version"
                $chartFile
            ) -Environment $queryEnvironment

            if ($currentVersion -ne $version) {
                $mutationEnvironment = @{
                    REQUESTED_DEPENDENCY = $dependency
                    TARGET_VERSION       = $version
                }
                Invoke-NativeProcess yq @(
                    '-i'
                    "($dependencyQuery).version = strenv(TARGET_VERSION)"
                    $chartFile
                ) -Environment $mutationEnvironment | Out-Null
                Invoke-NativeProcess helm @('dependency', 'update', $wrapper) | Out-Null
            }

            $actualVersion = Invoke-NativeProcess yq @(
                '-er'
                "$dependencyQuery | .version"
                $chartFile
            ) -Environment $queryEnvironment
            if ($actualVersion -ne $version) {
                throw 'Chart.yaml does not contain the requested dependency version'
            }
            if (-not (Test-Path -LiteralPath $lockFile -PathType Leaf)) {
                throw 'Chart.lock is missing after dependency update'
            }

            $lockedVersion = Invoke-NativeProcess yq @(
                '-er',
                '.dependencies[] | select(.name == strenv(DEPENDENCY_NAME)) | .version',
                $lockFile
            ) -Environment @{ DEPENDENCY_NAME = $dependencyName }
            if ($lockedVersion -ne $version) {
                throw 'Chart.lock does not contain the requested dependency version'
            }
            if (-not (Test-Path -LiteralPath $targetArchive -PathType Leaf)) {
                throw "vendored dependency archive is missing: $targetArchive"
            }
        }

        if ($image) {
            $valuesFile = (Resolve-Path (Join-Path $wrapper 'values.yaml')).Path
            $valuesRelative = [IO.Path]::GetRelativePath($checkout, $valuesFile).Replace('\', '/')
            $state.Protected += $valuesRelative
            $valuesEnvironment = @{ VALUES_ROOT = $valuesRoot }

            $typeCheck = Invoke-NativeProcess yq @(
                '-e',
                '(.[strenv(VALUES_ROOT)].image.tag | tag) == "!!str"',
                $valuesFile
            ) -Environment $valuesEnvironment -RawOutput -AllowFailure
            if ($typeCheck.ExitCode) {
                throw "$valuesFile must contain a string at $valuesRoot.image.tag"
            }

            $currentImage = Invoke-NativeProcess yq @(
                '-er'
                '.[strenv(VALUES_ROOT)].image.tag'
                $valuesFile
            ) -Environment $valuesEnvironment
            if ($currentImage -ne $image) {
                Invoke-NativeProcess yq @(
                    '-i',
                    '.[strenv(VALUES_ROOT)].image.tag = strenv(TARGET_IMAGE_TAG)',
                    $valuesFile
                ) -Environment @{
                    VALUES_ROOT      = $valuesRoot
                    TARGET_IMAGE_TAG = $image
                } | Out-Null
            }

            $actualImage = Invoke-NativeProcess yq @(
                '-er'
                '.[strenv(VALUES_ROOT)].image.tag'
                $valuesFile
            ) -Environment $valuesEnvironment
            if ($actualImage -ne $image) {
                throw 'values.yaml does not contain the requested image tag'
            }
        }

        Invoke-NativeProcess helm @('lint', $wrapper) | Out-Null
        $changedResult = Invoke-NativeProcess git @('-C', $checkout, 'diff', '--name-only', '-z') -RawOutput
        $untrackedArguments = @('-C', $checkout, 'ls-files', '--others', '--exclude-standard', '-z')
        $untrackedResult = Invoke-NativeProcess git $untrackedArguments -RawOutput
        $state.Changed = @($changedResult.StandardOutput.Split([char] 0, [StringSplitOptions]::RemoveEmptyEntries))
        $state.Changed += @($untrackedResult.StandardOutput.Split([char] 0, [StringSplitOptions]::RemoveEmptyEntries))

        foreach ($path in $state.Changed) {
            $isArchive = $version -and $path -like "$($state.Archives)/$($state.DependencyName)-*.tgz"
            if ($path -notin $state.Protected -and -not $isArchive) {
                throw "wrapper update changed unexpected path: $path"
            }
        }
    }

    function New-WrapperCommit {
        foreach ($path in $state.Changed) {
            Invoke-NativeProcess git @('-C', $checkout, 'add', '-A', '--', $path) | Out-Null
        }

        $message = if ($version -and $image) {
            (
                "feat: update umbrella chart for $chartName in $environment environment " +
                "for chart version $version and image tag $image"
            )
        } elseif ($version) {
            "feat: update umbrella chart for $chartName in $environment environment for chart version $version"
        } else {
            "feat: update umbrella chart for $chartName in $environment environment for image tag $image"
        }
        Invoke-NativeProcess git @('-C', $checkout, '-c', 'commit.gpgsign=false', 'commit', '-m', $message) | Out-Null
    }

    $base = Invoke-NativeProcess git @('-C', $checkout, 'rev-parse', 'HEAD')
    Invoke-WrapperMutation
    if (-not $state.Changed.Count) {
        Write-GitHubOutput 'commit-sha' $base
        return
    }

    New-WrapperCommit
    $pushArguments = @('-C', $checkout, 'push', 'origin', "HEAD:refs/heads/$targetRef")
    $push = Invoke-NativeProcess git $pushArguments -RawOutput -AllowFailure
    if (-not $push.ExitCode) {
        Write-GitHubOutput 'commit-sha' (Invoke-NativeProcess git @('-C', $checkout, 'rev-parse', 'HEAD'))
        return
    }

    Invoke-NativeProcess git @('-C', $checkout, 'fetch', '--no-tags', 'origin', "refs/heads/$targetRef") | Out-Null
    $remote = Invoke-NativeProcess git @('-C', $checkout, 'rev-parse', 'FETCH_HEAD')
    if ($remote -eq $base) {
        throw 'push failed without a concurrent target branch update'
    }
    $ancestryArguments = @('-C', $checkout, 'merge-base', '--is-ancestor', $base, $remote)
    $ancestry = Invoke-NativeProcess git $ancestryArguments -RawOutput -AllowFailure
    if ($ancestry.ExitCode) {
        throw 'target branch no longer descends from the checked-out base'
    }

    $remoteResult = Invoke-NativeProcess git @('-C', $checkout, 'diff', '--name-only', '-z', $base, $remote) -RawOutput
    $remoteChanged = @($remoteResult.StandardOutput.Split([char] 0, [StringSplitOptions]::RemoveEmptyEntries))
    foreach ($path in $remoteChanged) {
        $isArchive = $version -and $path -like "$($state.Archives)/$($state.DependencyName)-*.tgz"
        if ($path -in $state.Protected -or $isArchive) {
            throw "concurrent update changed protected wrapper state: $path"
        }
    }

    Invoke-NativeProcess git @('-C', $checkout, 'switch', '--detach', $remote) | Out-Null
    if (Invoke-NativeProcess git @('-C', $checkout, 'status', '--porcelain')) {
        throw 'target checkout was not clean after refresh'
    }

    Invoke-WrapperMutation
    if (-not $state.Changed.Count) {
        Write-GitHubOutput 'commit-sha' $remote
        return
    }

    New-WrapperCommit
    Invoke-NativeProcess git @('-C', $checkout, 'push', 'origin', "HEAD:refs/heads/$targetRef") | Out-Null
    Write-GitHubOutput 'commit-sha' (Invoke-NativeProcess git @('-C', $checkout, 'rev-parse', 'HEAD'))
}

Export-ModuleMember -Function Invoke-ChartUpdate
