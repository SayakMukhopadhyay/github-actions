#requires -Version 7.4

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'chart-update-deploy' 'ChartUpdate.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..' 'static-site-update-deploy' 'StaticSiteUpdate.psm1') -Force
}

Describe 'Chart update validation' {
    BeforeEach {
        $script:checkout = Join-Path $TestDrive 'gitops'
        $script:wrapper = Join-Path $script:checkout 'app/envs/prod'
        New-Item -ItemType Directory $script:wrapper -Force | Out-Null
        Set-Content (Join-Path $script:wrapper 'Chart.yaml') 'dependencies: []'
        Set-Content (Join-Path $script:wrapper 'values.yaml') 'app: {}'

        $env:GITHUB_WORKSPACE = $TestDrive
        $env:INPUT_CHECKOUT_PATH = 'gitops'
        $env:INPUT_ENVIRONMENT = 'prod'
        $env:INPUT_CHART_NAME = 'app'
        $env:INPUT_DEPENDENCY = $null
        $env:INPUT_CHART_VERSION = $null
        $env:INPUT_IMAGE_TAG = $null
        $env:INPUT_TARGET_REF = 'main'
        $env:INPUT_WRAPPER_CHART_PATH = $null

        Mock Invoke-NativeProcess -ModuleName ChartUpdate {
            if ($FilePath -eq 'yq' -and $ArgumentList[0] -eq '--version') {
                return 'yq version v4.53.3'
            }
            if ($FilePath -eq 'git' -and $ArgumentList -contains 'check-ref-format') {
                return [pscustomobject]@{
                    ExitCode       = 0
                    StandardOutput = ''
                    StandardError  = ''
                }
            }

            ''
        }
    }

    It 'requires a chart version or image tag' {
        { Invoke-ChartUpdate } | Should -Throw '*at least one*'
    }

    It 'rejects malformed semantic chart versions' {
        $env:INPUT_CHART_VERSION = '01.2.3'

        { Invoke-ChartUpdate } | Should -Throw '*exact semantic version*'
    }

    It 'rejects malformed container image tags' {
        $env:INPUT_IMAGE_TAG = 'bad tag'

        { Invoke-ChartUpdate } | Should -Throw '*valid container image tag*'
    }

    It 'rejects dependency names containing separators or newlines' {
        $env:INPUT_IMAGE_TAG = 'good'
        $env:INPUT_DEPENDENCY = 'owner/chart'

        { Invoke-ChartUpdate } | Should -Throw '*chart name or alias*'

        $env:INPUT_DEPENDENCY = "chart`nnext"
        { Invoke-ChartUpdate } | Should -Throw '*chart name or alias*'
    }

    It 'rejects an invalid target branch before mutation' {
        $env:INPUT_IMAGE_TAG = 'good'
        Mock Invoke-NativeProcess -ModuleName ChartUpdate `
            -ParameterFilter { $ArgumentList -contains 'check-ref-format' } `
            -MockWith {
            [pscustomobject]@{
                ExitCode       = 1
                StandardOutput = ''
                StandardError  = ''
            }
        }

        { Invoke-ChartUpdate } | Should -Throw '*valid branch name*'
    }
}

Describe 'Static-site update validation' {
    BeforeEach {
        $script:checkout = Join-Path $TestDrive 'static-gitops'
        $script:wrapper = Join-Path $script:checkout 'site/envs/prod'
        New-Item -ItemType Directory $script:wrapper -Force | Out-Null
        Set-Content (Join-Path $script:wrapper 'Chart.yaml') 'dependencies: []'
        Set-Content (Join-Path $script:wrapper 'values.yaml') 'staticSites: {}'

        $env:GITHUB_WORKSPACE = $TestDrive
        $env:INPUT_CHECKOUT_PATH = 'static-gitops'
        $env:INPUT_ENVIRONMENT = 'prod'
        $env:INPUT_CHART_NAME = 'site'
        $env:INPUT_IMAGE_VERSION = 'bad tag'
        $env:INPUT_TARGET_REF = 'main'
        $env:INPUT_WRAPPER_CHART_PATH = $null

        Mock Invoke-NativeProcess -ModuleName StaticSiteUpdate {
            if ($FilePath -eq 'yq' -and $ArgumentList[0] -eq '--version') {
                return 'yq version v4.53.3'
            }
            if ($FilePath -eq 'git' -and $ArgumentList -contains 'check-ref-format') {
                return [pscustomobject]@{
                    ExitCode       = 0
                    StandardOutput = ''
                    StandardError  = ''
                }
            }

            ''
        }
    }

    It 'rejects malformed image versions' {
        { Invoke-StaticSiteUpdate } | Should -Throw '*valid container image tag*'
    }

    It 'requires exactly one fixed static-sites dependency' {
        $env:INPUT_IMAGE_VERSION = 'good'
        Mock Invoke-NativeProcess -ModuleName StaticSiteUpdate `
            -ParameterFilter { $FilePath -eq 'yq' -and $ArgumentList[0] -eq '-er' } `
            -MockWith { '2' }

        { Invoke-StaticSiteUpdate } | Should -Throw '*exactly one dependency*'
    }
}
