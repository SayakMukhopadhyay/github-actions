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
        throw "$Label escapes the target checkout"
    }
}

function Invoke-StaticSiteUpdate {
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
    $imageVersion = Assert-SingleLine $env:INPUT_IMAGE_VERSION 'image-version'
    $targetRef = if ($env:INPUT_TARGET_REF) {
        $env:INPUT_TARGET_REF
    } else {
        'main'
    }

    if ($imageVersion -notmatch '^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$') {
        throw 'image-version must be a valid container image tag'
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

    $chartFile = (Resolve-Path (Join-Path $wrapper 'Chart.yaml')).Path
    $valuesFile = (Resolve-Path (Join-Path $wrapper 'values.yaml')).Path
    Assert-ContainedPath -Parent $checkout -Child $chartFile -Label 'wrapper file'
    Assert-ContainedPath -Parent $checkout -Child $valuesFile -Label 'wrapper file'

    $count = Invoke-NativeProcess yq @(
        '-er'
        '[.dependencies[]? | select(.name == "static-sites")] | length'
        $chartFile
    )
    if ($count -ne '1') {
        throw "$chartFile must contain exactly one dependency named 'static-sites'; found $count"
    }
    $alias = Invoke-NativeProcess yq @('-er', '.dependencies[] | select(.name == "static-sites") | .alias', $chartFile)
    if ($alias -ne 'staticSites') {
        throw "the static-sites dependency must define alias 'staticSites'; found '$alias'"
    }

    $typeCheck = Invoke-NativeProcess yq @(
        '-e'
        '(.staticSites.image.tag | tag) == "!!str"'
        $valuesFile
    ) -RawOutput -AllowFailure
    if ($typeCheck.ExitCode) {
        throw "$valuesFile must contain a string at staticSites.image.tag"
    }
    if ((Invoke-NativeProcess yq @('-er', '.staticSites.image.tag', $valuesFile)) -eq $imageVersion) {
        Write-Output "Static site $chartName is already pinned to image version $imageVersion in $environment"
        return
    }

    Invoke-NativeProcess yq @(
        '-i'
        '.staticSites.image.tag = strenv(IMAGE_VERSION)'
        $valuesFile
    ) -Environment @{ IMAGE_VERSION = $imageVersion } | Out-Null
    Invoke-NativeProcess helm @('lint', $wrapper) | Out-Null
    if ((Invoke-NativeProcess yq @('-er', '.staticSites.image.tag', $valuesFile)) -ne $imageVersion) {
        throw 'values.yaml does not contain the requested image version'
    }

    $relative = [IO.Path]::GetRelativePath($checkout, $valuesFile).Replace('\', '/')
    $changedResult = Invoke-NativeProcess git @('-C', $checkout, 'diff', '--name-only', '-z') -RawOutput
    $untrackedArguments = @('-C', $checkout, 'ls-files', '--others', '--exclude-standard', '-z')
    $untrackedResult = Invoke-NativeProcess git $untrackedArguments -RawOutput
    $changed = @($changedResult.StandardOutput.Split([char] 0, [StringSplitOptions]::RemoveEmptyEntries))
    $changed += @($untrackedResult.StandardOutput.Split([char] 0, [StringSplitOptions]::RemoveEmptyEntries))

    if (-not $changed.Count) {
        throw 'updating staticSites.image.tag did not change the target repository'
    }
    foreach ($path in $changed) {
        if ($path -ne $relative) {
            throw "static-site update changed unexpected path: $path"
        }
    }

    Invoke-NativeProcess git @('-C', $checkout, 'add', '--', $relative) | Out-Null
    Invoke-NativeProcess git @('-C', $checkout, 'config', 'user.name', 'github-actions[bot]') | Out-Null
    $botEmail = '41898282+github-actions[bot]@users.noreply.github.com'
    Invoke-NativeProcess git @('-C', $checkout, 'config', 'user.email', $botEmail) | Out-Null
    $message = "feat: update static site $chartName in $environment environment to image version $imageVersion"
    Invoke-NativeProcess git @('-C', $checkout, '-c', 'commit.gpgsign=false', 'commit', '-m', $message) | Out-Null
    Invoke-NativeProcess git @('-C', $checkout, 'push', 'origin', "HEAD:refs/heads/$targetRef") | Out-Null
}

Export-ModuleMember -Function Invoke-StaticSiteUpdate
