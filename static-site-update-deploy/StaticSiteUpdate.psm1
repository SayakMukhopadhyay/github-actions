#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'ActionRuntime.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'GitOpsChartUpdate.psm1')

function Invoke-StaticSiteUpdate {
    $environment = Assert-SingleLine $env:INPUT_ENVIRONMENT environment
    $chartName = Assert-SingleLine $env:INPUT_CHART_NAME 'chart-name'
    $imageVersion = Assert-SingleLine $env:INPUT_IMAGE_VERSION 'image-version'
    $targetRef = if ($env:INPUT_TARGET_REF) {
        $env:INPUT_TARGET_REF
    } else {
        'main'
    }
    $message = "feat: update static site $chartName in $environment environment to image version $imageVersion"
    $noOpMessage = "Static site $chartName is already pinned to image version $imageVersion in $environment"

    $configuration = @{
        Environment             = $environment
        ChartName               = $chartName
        Dependency              = 'static-sites'
        TargetRef               = $targetRef
        CommitMessage           = $message
        CheckoutPath            = $env:INPUT_CHECKOUT_PATH
        WrapperChartPath        = $env:INPUT_WRAPPER_CHART_PATH
        ImageTag                = $imageVersion
        RequiredDependencyName  = 'static-sites'
        RequiredDependencyAlias = 'staticSites'
        NoOpMessage             = $noOpMessage
    }
    Invoke-GitOpsChartUpdate @configuration
}

Export-ModuleMember -Function Invoke-StaticSiteUpdate
