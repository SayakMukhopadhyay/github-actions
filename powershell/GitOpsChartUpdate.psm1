#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'ActionRuntime.psm1') -Force

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

function Invoke-GitOpsChartUpdate {
    param(
        [Parameter(Mandatory)] [string] $Environment,
        [Parameter(Mandatory)] [string] $ChartName,
        [Parameter(Mandatory)] [string] $Dependency,
        [Parameter(Mandatory)] [string] $TargetRef,
        [Parameter(Mandatory)] [string] $CommitMessage,
        [string] $CheckoutPath = '.gitops-charts',
        [string] $WrapperChartPath = '',
        [string] $ChartVersion = '',
        [string] $ImageTag = '',
        [string] $RequiredDependencyName = '',
        [string] $RequiredDependencyAlias = '',
        [string] $NoOpMessage = '',
        [switch] $EmitCommitSha
    )

    if (-not $CheckoutPath) {
        $CheckoutPath = '.gitops-charts'
    }
    $workspaceInput = if ($env:GITHUB_WORKSPACE) {
        $env:GITHUB_WORKSPACE
    } else {
        (Get-Location).Path
    }
    $workspace = (Resolve-Path $workspaceInput).Path
    $checkout = (Resolve-Path (Join-Path $workspace $CheckoutPath)).Path
    Assert-ContainedPath -Parent $workspace -Child $checkout -Label 'target checkout'

    if (Invoke-NativeProcess git @('-C', $checkout, 'status', '--porcelain')) {
        throw 'target repository checkout is not clean'
    }
    if ((Invoke-NativeProcess yq @('--version')) -notmatch 'version\s+v?4\.') {
        throw 'yq v4 is required'
    }
    if (-not $ChartVersion -and -not $ImageTag) {
        throw 'at least one of chart-version or image-tag is required'
    }
    if ($ChartVersion -and $ChartVersion -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?$') {
        throw 'chart-version must be an exact semantic version'
    }
    if ($ImageTag -and $ImageTag -notmatch '^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$') {
        throw 'image-tag must be a valid container image tag'
    }
    if ($Dependency.Contains('/') -or $Dependency.Contains("`n") -or $Dependency.Contains("`r")) {
        throw 'dependency must be a chart name or alias'
    }

    $refCheck = Invoke-NativeProcess git @('check-ref-format', '--branch', $TargetRef) -RawOutput -AllowFailure
    if ($refCheck.ExitCode) {
        throw 'target-ref must be a valid branch name'
    }

    $wrapperRelative = if ($WrapperChartPath) {
        $WrapperChartPath
    } else {
        "$ChartName/envs/$Environment"
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
        Assert-ContainedPath -Parent $checkout -Child $chartFile -Label 'wrapper file'
        $lockFile = Join-Path $wrapper 'Chart.lock'
        $queryEnvironment = @{ REQUESTED_DEPENDENCY = $Dependency }
        $dependencyQuery = (
            '.dependencies[] | ' +
            'select(.name == strenv(REQUESTED_DEPENDENCY) or .alias == strenv(REQUESTED_DEPENDENCY))'
        )

        $count = Invoke-NativeProcess yq @('-er', "[$dependencyQuery] | length", $chartFile) -Environment $queryEnvironment
        if ($count -ne '1') {
            throw "$chartFile must contain exactly one dependency matching '$Dependency'; found $count"
        }

        $dependencyName = Invoke-NativeProcess yq @('-er', "$dependencyQuery | .name", $chartFile) -Environment $queryEnvironment
        $alias = Invoke-NativeProcess yq @('-er', "$dependencyQuery | .alias // `"`"", $chartFile) -Environment $queryEnvironment
        foreach ($coordinate in $dependencyName, $alias) {
            if ($coordinate.Contains('/') -or $coordinate.Contains("`n") -or $coordinate.Contains("`r")) {
                throw 'selected dependency name or alias is invalid'
            }
        }
        if ([string]::IsNullOrWhiteSpace($dependencyName)) {
            throw 'selected dependency name or alias is invalid'
        }
        if ($RequiredDependencyName -and $dependencyName -ne $RequiredDependencyName) {
            throw "$chartFile must contain exactly one dependency named '$RequiredDependencyName'; found '$dependencyName'"
        }
        if ($RequiredDependencyAlias -and $alias -ne $RequiredDependencyAlias) {
            throw "the $RequiredDependencyName dependency must define alias '$RequiredDependencyAlias'; found '$alias'"
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

        if ($ChartVersion) {
            $lockRelative = [IO.Path]::GetRelativePath($checkout, $lockFile).Replace('\', '/')
            $state.Protected += $chartRelative, $lockRelative
            $targetArchive = Join-Path $wrapper "charts/$dependencyName-$ChartVersion.tgz"
            $currentVersion = Invoke-NativeProcess yq @('-er', "$dependencyQuery | .version", $chartFile) -Environment $queryEnvironment

            if ($currentVersion -ne $ChartVersion) {
                $mutationEnvironment = @{
                    REQUESTED_DEPENDENCY = $Dependency
                    TARGET_VERSION       = $ChartVersion
                }
                Invoke-NativeProcess yq @('-i', "($dependencyQuery).version = strenv(TARGET_VERSION)", $chartFile) -Environment $mutationEnvironment | Out-Null
                Invoke-NativeProcess helm @('dependency', 'update', $wrapper) | Out-Null
            }

            $actualVersion = Invoke-NativeProcess yq @('-er', "$dependencyQuery | .version", $chartFile) -Environment $queryEnvironment
            if ($actualVersion -ne $ChartVersion) {
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
            if ($lockedVersion -ne $ChartVersion) {
                throw 'Chart.lock does not contain the requested dependency version'
            }
            if (-not (Test-Path -LiteralPath $targetArchive -PathType Leaf)) {
                throw "vendored dependency archive is missing: $targetArchive"
            }
        }

        if ($ImageTag) {
            $valuesFile = (Resolve-Path (Join-Path $wrapper 'values.yaml')).Path
            Assert-ContainedPath -Parent $checkout -Child $valuesFile -Label 'wrapper file'
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

            $currentImage = Invoke-NativeProcess yq @('-er', '.[strenv(VALUES_ROOT)].image.tag', $valuesFile) -Environment $valuesEnvironment
            if ($currentImage -ne $ImageTag) {
                Invoke-NativeProcess yq @(
                    '-i',
                    '.[strenv(VALUES_ROOT)].image.tag = strenv(TARGET_IMAGE_TAG)',
                    $valuesFile
                ) -Environment @{
                    VALUES_ROOT      = $valuesRoot
                    TARGET_IMAGE_TAG = $ImageTag
                } | Out-Null
            }

            $actualImage = Invoke-NativeProcess yq @('-er', '.[strenv(VALUES_ROOT)].image.tag', $valuesFile) -Environment $valuesEnvironment
            if ($actualImage -ne $ImageTag) {
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
            $isArchive = $ChartVersion -and $path -like "$($state.Archives)/$($state.DependencyName)-*.tgz"
            if ($path -notin $state.Protected -and -not $isArchive) {
                throw "wrapper update changed unexpected path: $path"
            }
        }
    }

    function New-WrapperCommit {
        foreach ($path in $state.Changed) {
            Invoke-NativeProcess git @('-C', $checkout, 'add', '-A', '--', $path) | Out-Null
        }
        Invoke-NativeProcess git @('-C', $checkout, '-c', 'commit.gpgsign=false', 'commit', '-m', $CommitMessage) | Out-Null
    }

    function Complete-Update([string] $CommitSha) {
        if ($EmitCommitSha) {
            Write-GitHubOutput 'commit-sha' $CommitSha
        }
    }

    $base = Invoke-NativeProcess git @('-C', $checkout, 'rev-parse', 'HEAD')
    Invoke-WrapperMutation
    if (-not $state.Changed.Count) {
        if ($NoOpMessage) {
            Write-Output $NoOpMessage
        }
        Complete-Update $base
        return
    }

    New-WrapperCommit
    $pushArguments = @('-C', $checkout, 'push', 'origin', "HEAD:refs/heads/$TargetRef")
    $push = Invoke-NativeProcess git $pushArguments -RawOutput -AllowFailure
    if (-not $push.ExitCode) {
        Complete-Update (Invoke-NativeProcess git @('-C', $checkout, 'rev-parse', 'HEAD'))
        return
    }

    Invoke-NativeProcess git @('-C', $checkout, 'fetch', '--no-tags', 'origin', "refs/heads/$TargetRef") | Out-Null
    $remote = Invoke-NativeProcess git @('-C', $checkout, 'rev-parse', 'FETCH_HEAD')
    if ($remote -eq $base) {
        throw 'push failed without a concurrent target branch update'
    }
    $ancestry = Invoke-NativeProcess git @('-C', $checkout, 'merge-base', '--is-ancestor', $base, $remote) -RawOutput -AllowFailure
    if ($ancestry.ExitCode) {
        throw 'target branch no longer descends from the checked-out base'
    }

    $remoteResult = Invoke-NativeProcess git @('-C', $checkout, 'diff', '--name-only', '-z', $base, $remote) -RawOutput
    $remoteChanged = @($remoteResult.StandardOutput.Split([char] 0, [StringSplitOptions]::RemoveEmptyEntries))
    foreach ($path in $remoteChanged) {
        $isArchive = $ChartVersion -and $path -like "$($state.Archives)/$($state.DependencyName)-*.tgz"
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
        if ($NoOpMessage) {
            Write-Output $NoOpMessage
        }
        Complete-Update $remote
        return
    }

    New-WrapperCommit
    Invoke-NativeProcess git $pushArguments | Out-Null
    Complete-Update (Invoke-NativeProcess git @('-C', $checkout, 'rev-parse', 'HEAD'))
}

Export-ModuleMember -Function Invoke-GitOpsChartUpdate
