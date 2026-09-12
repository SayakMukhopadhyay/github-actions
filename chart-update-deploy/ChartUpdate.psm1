#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'ActionRuntime.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'GitOpsChartUpdate.psm1')

function Invoke-ChartUpdate {
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

    $configuration = @{
        Environment      = $environment
        ChartName        = $chartName
        Dependency       = $dependency
        TargetRef        = $targetRef
        CommitMessage    = $message
        CheckoutPath     = $env:INPUT_CHECKOUT_PATH
        WrapperChartPath = $env:INPUT_WRAPPER_CHART_PATH
        ChartVersion     = $version
        ImageTag         = $image
        EmitCommitSha    = $true
    }
    Invoke-GitOpsChartUpdate @configuration
}

Export-ModuleMember -Function Invoke-ChartUpdate
