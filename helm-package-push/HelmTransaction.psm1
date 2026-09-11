#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'ActionRuntime.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'OciArtifactProbe.psm1') -Force

function Invoke-HelmTransaction {
    $workspaceInput = if ($env:GITHUB_WORKSPACE) {
        $env:GITHUB_WORKSPACE
    } else {
        (Get-Location).Path
    }
    $workspace = (Resolve-Path $workspaceInput).Path
    $chart = (Resolve-Path $env:INPUT_CHART_DIRECTORY).Path
    $chartRelative = [IO.Path]::GetRelativePath($workspace, $chart)
    if ($chartRelative -eq '..' -or $chartRelative.StartsWith("..$([IO.Path]::DirectorySeparatorChar)")) {
        throw 'chart directory escapes the checkout'
    }

    $repositoriesFile = (Resolve-Path $env:INPUT_REPOSITORIES_FILE).Path
    $runnerTemp = (Resolve-Path $env:RUNNER_TEMP).Path
    $repositoriesRelative = [IO.Path]::GetRelativePath($runnerTemp, $repositoriesFile)
    if ($repositoriesRelative -eq '..' -or $repositoriesRelative.StartsWith("..$([IO.Path]::DirectorySeparatorChar)")) {
        throw 'dependency repositories file escapes RUNNER_TEMP'
    }

    $chartName = Assert-SingleLine $env:INPUT_CHART_NAME 'chart-name'
    $chartVersion = Assert-SingleLine $env:INPUT_CHART_VERSION 'chart-version'
    if ($chartName.StartsWith('-') -or $chartName.Contains('/') -or $chartName.Contains('\')) {
        throw 'chart-name is unsafe'
    }
    if ($chartVersion -notmatch '^((0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)|0\.0\.0-build-[0-9a-f]{40})$') {
        throw 'chart-version is invalid'
    }

    $destination = $null
    if ($env:INPUT_PUSH -eq 'true') {
        $registry = if ($env:INPUT_REGISTRY) {
            $env:INPUT_REGISTRY
        } else {
            'ghcr.io'
        }
        $repository = if ($env:INPUT_REPOSITORY) {
            $env:INPUT_REPOSITORY
        } elseif ($env:REPOSITORY_OWNER) {
            "$env:REPOSITORY_OWNER/charts"
        } else {
            throw 'github.repository_owner is required'
        }
        $destination = "oci://$($registry.ToLowerInvariant())/$($repository.ToLowerInvariant())"

        $probe = Invoke-OciArtifactProbe helm @(
            'show'
            'chart'
            "$destination/$chartName"
            '--version'
            $chartVersion
        )
        if ($probe.Exists) {
            return
        }
    }

    Push-Location $chart
    try {
        $records = [IO.File]::ReadAllBytes($repositoriesFile)
        $text = [Text.Encoding]::UTF8.GetString($records)
        $parts = $text.Split([char] 0, [StringSplitOptions]::RemoveEmptyEntries)
        if ($parts.Count % 2) {
            throw 'dependency repositories file is truncated'
        }

        for ($index = 0; $index -lt $parts.Count; $index += 2) {
            $name = $parts[$index]
            $url = $parts[$index + 1]
            if (-not $name -or $name.StartsWith('-') -or $name.Contains("`n") -or $name.Contains("`r")) {
                throw 'dependency repository name is unsafe'
            }
            if ($url -notmatch '^https?://') {
                throw 'dependency repository URL is unsafe'
            }
            Invoke-NativeProcess helm @('repo', 'add', $name, $url) | Out-Null
        }

        Invoke-NativeProcess helm @('dependency', 'build') | Out-Null
        Invoke-NativeProcess helm @('lint', '.') | Out-Null

        $packageArguments = @('package', '.', '--version', $chartVersion)
        if ($env:INPUT_APP_VERSION) {
            $packageArguments += @('--app-version', $env:INPUT_APP_VERSION)
        }
        Invoke-NativeProcess helm $packageArguments | Out-Null

        $packagePath = "$chartName-$chartVersion.tgz"
        if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
            throw "Helm did not create the expected package: $chart/$packagePath"
        }

        if ($env:INPUT_PUSH -eq 'true') {
            Invoke-NativeProcess helm @('push', $packagePath, $destination) | Out-Null
        }
    } finally {
        Pop-Location
    }
}

Export-ModuleMember -Function Invoke-HelmTransaction
