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

        Mock Invoke-NativeProcess -ModuleName GitOpsChartUpdate {
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
        Mock Invoke-NativeProcess -ModuleName GitOpsChartUpdate `
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

        Mock Invoke-NativeProcess -ModuleName GitOpsChartUpdate {
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
        Mock Invoke-NativeProcess -ModuleName GitOpsChartUpdate `
            -ParameterFilter { $FilePath -eq 'yq' -and $ArgumentList[0] -eq '-er' } `
            -MockWith { '2' }

        { Invoke-StaticSiteUpdate } | Should -Throw '*exactly one dependency*'
    }
}

Describe 'Chart update transaction behavior' {
    BeforeEach {
        $script:checkout = Join-Path $TestDrive 'gitops-transaction'
        $script:wrapper = Join-Path $script:checkout 'app/envs/prod'
        New-Item -ItemType Directory (Join-Path $script:wrapper 'charts') -Force | Out-Null
        Set-Content (Join-Path $script:wrapper 'Chart.yaml') 'dependencies: []'
        Set-Content (Join-Path $script:wrapper 'values.yaml') 'app: {}'

        $env:GITHUB_WORKSPACE = $TestDrive
        $env:GITHUB_OUTPUT = Join-Path $TestDrive 'chart-output'
        $env:INPUT_CHECKOUT_PATH = 'gitops-transaction'
        $env:INPUT_ENVIRONMENT = 'prod'
        $env:INPUT_CHART_NAME = 'app'
        $env:INPUT_DEPENDENCY = $null
        $env:INPUT_CHART_VERSION = $null
        $env:INPUT_IMAGE_TAG = $null
        $env:INPUT_TARGET_REF = 'main'
        $env:INPUT_WRAPPER_CHART_PATH = $null

        $script:dependencyName = 'app'
        $script:dependencyAlias = 'app'
        $global:TestDependencyVersion = '1.0.0'
        $script:imageTag = 'old'
        $script:initialDependencyVersion = $global:TestDependencyVersion
        $script:initialImageTag = $script:imageTag
        $script:changedPaths = @()
        $script:untrackedPaths = @()
        $script:extraChangedPaths = @()
        $script:base = '1' * 40
        $script:head = $script:base
        $script:remote = $script:base
        $script:remoteChangedPaths = @()
        $script:ancestryExitCode = 0
        $script:pushExitCodes = [Collections.Generic.Queue[int]]::new()
        $script:pushExitCodes.Enqueue(0)
        $script:pushCount = 0

        Mock Invoke-NativeProcess -ModuleName GitOpsChartUpdate {
            if ($FilePath -eq 'yq') {
                if ($ArgumentList[0] -eq '--version') {
                    return 'yq version v4.53.3'
                }

                $expression = [string] $ArgumentList[1]
                $targetFile = [string] $ArgumentList[-1]
                if ($ArgumentList[0] -eq '-i') {
                    if ($expression -match '\.version') {
                        $global:TestDependencyVersion = $env:INPUT_CHART_VERSION
                        $script:changedPaths = @('app/envs/prod/Chart.yaml')
                    } else {
                        $script:imageTag = $env:INPUT_IMAGE_TAG
                        $script:changedPaths += 'app/envs/prod/values.yaml'
                    }
                    return ''
                }
                if ($ArgumentList[0] -eq '-e') {
                    return [pscustomobject]@{
                        ExitCode       = 0
                        StandardOutput = ''
                        StandardError  = ''
                    }
                }
                if ($expression -match '\| length') {
                    return '1'
                }
                if ($expression -match '\.name$') {
                    return $script:dependencyName
                }
                if ($expression -match '\.alias //') {
                    return $script:dependencyAlias
                }
                if ($expression -match '\.version') {
                    return $global:TestDependencyVersion
                }
                if ($expression -match 'image\.tag') {
                    return $script:imageTag
                }

                throw "Unexpected yq invocation: $($ArgumentList -join ' ') against $targetFile"
            }

            if ($FilePath -eq 'helm') {
                if ($ArgumentList[0] -eq 'dependency') {
                    $lock = Join-Path $script:wrapper 'Chart.lock'
                    $archive = Join-Path $script:wrapper "charts/$script:dependencyName-$global:TestDependencyVersion.tgz"
                    New-Item -ItemType File $lock, $archive -Force | Out-Null
                    $script:changedPaths += 'app/envs/prod/Chart.lock'
                    $script:untrackedPaths = @("app/envs/prod/charts/$script:dependencyName-$global:TestDependencyVersion.tgz")
                }
                return ''
            }

            if ($FilePath -ne 'git') {
                throw "Unexpected native process: $FilePath"
            }
            if ($ArgumentList -contains 'check-ref-format') {
                return [pscustomobject]@{ ExitCode = 0; StandardOutput = ''; StandardError = '' }
            }
            if ($ArgumentList -contains 'status') {
                return ''
            }
            if ($ArgumentList -contains 'config' -or $ArgumentList -contains 'add') {
                return ''
            }
            if ($ArgumentList -contains 'ls-files') {
                $text = if ($script:untrackedPaths.Count) {
                    ($script:untrackedPaths -join [char] 0) + [char] 0
                } else {
                    ''
                }
                return [pscustomobject]@{ ExitCode = 0; StandardOutput = $text; StandardError = '' }
            }
            if ($ArgumentList -contains 'diff') {
                $paths = if ($ArgumentList -contains $script:base -and $ArgumentList -contains $script:remote) {
                    $script:remoteChangedPaths
                } else {
                    @($script:changedPaths) + @($script:extraChangedPaths)
                }
                $text = if (@($paths).Count) {
                    ($paths -join [char] 0) + [char] 0
                } else {
                    ''
                }
                return [pscustomobject]@{ ExitCode = 0; StandardOutput = $text; StandardError = '' }
            }
            if ($ArgumentList -contains 'commit') {
                $script:head = '2' * 40
                return ''
            }
            if ($ArgumentList -contains 'push') {
                $script:pushCount++
                $exitCode = if ($script:pushExitCodes.Count) {
                    $script:pushExitCodes.Dequeue()
                } else {
                    0
                }
                $allowFailureRequested = [bool] (Get-Variable -Name AllowFailure -ValueOnly -ErrorAction SilentlyContinue)
                if ($exitCode -and -not $allowFailureRequested) {
                    throw 'second push failed'
                }
                return [pscustomobject]@{ ExitCode = $exitCode; StandardOutput = ''; StandardError = '' }
            }
            if ($ArgumentList -contains 'fetch') {
                return ''
            }
            if ($ArgumentList -contains 'merge-base') {
                return [pscustomobject]@{
                    ExitCode       = $script:ancestryExitCode
                    StandardOutput = ''
                    StandardError  = ''
                }
            }
            if ($ArgumentList -contains 'switch') {
                $script:head = $script:remote
                $global:TestDependencyVersion = $script:initialDependencyVersion
                $script:imageTag = $script:initialImageTag
                $script:changedPaths = @()
                $script:untrackedPaths = @()
                return ''
            }
            if ($ArgumentList -contains 'rev-parse') {
                if ($ArgumentList -contains 'FETCH_HEAD') {
                    return $script:remote
                }
                return $script:head
            }

            throw "Unexpected git invocation: $($ArgumentList -join ' ')"
        }
    }

    It 'commits an image-only update and publishes the resulting commit SHA' {
        $env:INPUT_IMAGE_TAG = 'build-123'

        Invoke-ChartUpdate

        Should -Invoke Invoke-NativeProcess -ModuleName GitOpsChartUpdate -Times 1 -ParameterFilter {
            $FilePath -eq 'helm' -and ($ArgumentList -join ' ') -like 'lint *'
        }
        Should -Invoke Invoke-NativeProcess -ModuleName GitOpsChartUpdate -Times 1 -ParameterFilter {
            $FilePath -eq 'git' -and $ArgumentList -contains 'commit'
        }
        (Get-Content -Raw $env:GITHUB_OUTPUT) | Should -Match "commit-sha=$('2' * 40)"
    }

    It 'commits a chart-only update with its lock and exact dependency archive' {
        $env:INPUT_CHART_VERSION = '2.0.0'

        Invoke-ChartUpdate

        Should -Invoke Invoke-NativeProcess -ModuleName GitOpsChartUpdate -Times 1 -ParameterFilter {
            $FilePath -eq 'helm' -and ($ArgumentList -join ' ') -like 'dependency update *'
        }
        $script:untrackedPaths | Should -Be @('app/envs/prod/charts/app-2.0.0.tgz')
        (Get-Content -Raw $env:GITHUB_OUTPUT) | Should -Match "commit-sha=$('2' * 40)"
    }

    It 'commits chart and image mutations atomically' {
        $env:INPUT_CHART_VERSION = '2.0.0'
        $env:INPUT_IMAGE_TAG = 'build-123'

        Invoke-ChartUpdate

        Should -Invoke Invoke-NativeProcess -ModuleName GitOpsChartUpdate -Times 1 -ParameterFilter {
            $FilePath -eq 'git' -and $ArgumentList -contains 'commit' -and
            ($ArgumentList -join ' ') -match 'chart version 2\.0\.0 and image tag build-123'
        }
        $script:pushCount | Should -Be 1
    }

    It 'lints a genuine no-op and emits the checked-out commit SHA' {
        $env:INPUT_IMAGE_TAG = $script:imageTag

        Invoke-ChartUpdate

        Should -Invoke Invoke-NativeProcess -ModuleName GitOpsChartUpdate -Times 1 -ParameterFilter {
            $FilePath -eq 'helm' -and ($ArgumentList -join ' ') -like 'lint *'
        }
        Should -Invoke Invoke-NativeProcess -ModuleName GitOpsChartUpdate -Times 0 -ParameterFilter {
            $FilePath -eq 'git' -and $ArgumentList -contains 'commit'
        }
        $script:pushCount | Should -Be 0
        (Get-Content -Raw $env:GITHUB_OUTPUT) | Should -Match "commit-sha=$script:base"
    }

    It 'rejects any changed path outside the selected wrapper state' {
        $env:INPUT_IMAGE_TAG = 'build-123'
        $script:extraChangedPaths = @('README.md')

        { Invoke-ChartUpdate } | Should -Throw '*unexpected path: README.md*'

        Should -Invoke Invoke-NativeProcess -ModuleName GitOpsChartUpdate -Times 0 -ParameterFilter {
            $FilePath -eq 'git' -and $ArgumentList -contains 'commit'
        }
    }

    It 'reapplies once after an unrelated concurrent update' {
        $env:INPUT_IMAGE_TAG = 'build-123'
        $script:pushExitCodes.Clear()
        $script:pushExitCodes.Enqueue(1)
        $script:pushExitCodes.Enqueue(0)
        $script:remote = '3' * 40
        $script:remoteChangedPaths = @('unrelated.yaml')

        Invoke-ChartUpdate

        $script:pushCount | Should -Be 2
        Should -Invoke Invoke-NativeProcess -ModuleName GitOpsChartUpdate -Times 1 -ParameterFilter {
            $FilePath -eq 'git' -and $ArgumentList -contains 'switch' -and $ArgumentList -contains $script:remote
        }
    }

    It 'fails closed when a concurrent update changes protected wrapper state' {
        $env:INPUT_IMAGE_TAG = 'build-123'
        $script:pushExitCodes.Clear()
        $script:pushExitCodes.Enqueue(1)
        $script:remote = '3' * 40
        $script:remoteChangedPaths = @('app/envs/prod/values.yaml')

        { Invoke-ChartUpdate } | Should -Throw '*concurrent update changed protected wrapper state*'

        $script:pushCount | Should -Be 1
    }

    It 'fails closed when the remote branch no longer descends from the base' {
        $env:INPUT_IMAGE_TAG = 'build-123'
        $script:pushExitCodes.Clear()
        $script:pushExitCodes.Enqueue(1)
        $script:remote = '3' * 40
        $script:ancestryExitCode = 1

        { Invoke-ChartUpdate } | Should -Throw '*no longer descends*'

        $script:pushCount | Should -Be 1
    }

    It 'propagates a second push failure without forcing the target branch' {
        $env:INPUT_IMAGE_TAG = 'build-123'
        $script:pushExitCodes.Clear()
        $script:pushExitCodes.Enqueue(1)
        $script:pushExitCodes.Enqueue(1)
        $script:remote = '3' * 40
        $script:remoteChangedPaths = @('unrelated.yaml')

        { Invoke-ChartUpdate } | Should -Throw '*second push failed*'

        $script:pushCount | Should -Be 2
        Should -Invoke Invoke-NativeProcess -ModuleName GitOpsChartUpdate -Times 0 -ParameterFilter {
            $FilePath -eq 'git' -and $ArgumentList -contains '--force'
        }
    }
}

Describe 'Static-site update transaction behavior' {
    BeforeEach {
        $script:checkout = Join-Path $TestDrive 'static-transaction'
        $script:wrapper = Join-Path $script:checkout 'site/envs/prod'
        New-Item -ItemType Directory $script:wrapper -Force | Out-Null
        Set-Content (Join-Path $script:wrapper 'Chart.yaml') 'dependencies: []'
        Set-Content (Join-Path $script:wrapper 'values.yaml') 'staticSites: {}'

        $env:GITHUB_WORKSPACE = $TestDrive
        $env:INPUT_CHECKOUT_PATH = 'static-transaction'
        $env:INPUT_ENVIRONMENT = 'prod'
        $env:INPUT_CHART_NAME = 'site'
        $env:INPUT_IMAGE_VERSION = 'build-123'
        $env:INPUT_TARGET_REF = 'main'
        $env:INPUT_WRAPPER_CHART_PATH = $null

        $script:staticImage = 'old'
        $script:staticInitialImage = $script:staticImage
        $script:staticAlias = 'staticSites'
        $script:staticChanged = @()
        $script:staticExtraChanged = @()
        $script:staticBase = '4' * 40
        $script:staticHead = $script:staticBase
        $script:staticRemote = $script:staticBase
        $script:staticRemoteChanged = @()
        $script:staticAncestryExitCode = 0
        $script:staticPushExitCodes = [Collections.Generic.Queue[int]]::new()
        $script:staticPushExitCodes.Enqueue(0)
        $script:staticPushCount = 0

        Mock Invoke-NativeProcess -ModuleName GitOpsChartUpdate {
            if ($FilePath -eq 'yq') {
                if ($ArgumentList[0] -eq '--version') {
                    return 'yq version v4.53.3'
                }
                $expression = [string] $ArgumentList[1]
                if ($ArgumentList[0] -eq '-i') {
                    $script:staticImage = $env:INPUT_IMAGE_VERSION
                    $script:staticChanged = @('site/envs/prod/values.yaml')
                    return ''
                }
                if ($ArgumentList[0] -eq '-e') {
                    return [pscustomobject]@{ ExitCode = 0; StandardOutput = ''; StandardError = '' }
                }
                if ($expression -match '\| length') {
                    return '1'
                }
                if ($expression -match '\.name$') {
                    return 'static-sites'
                }
                if ($expression -match '\.alias') {
                    return $script:staticAlias
                }
                if ($expression -match 'image\.tag') {
                    return $script:staticImage
                }
            }
            if ($FilePath -eq 'helm') {
                return ''
            }
            if ($FilePath -eq 'git') {
                if ($ArgumentList -contains 'check-ref-format') {
                    return [pscustomobject]@{ ExitCode = 0; StandardOutput = ''; StandardError = '' }
                }
                if ($ArgumentList -contains 'status' -or $ArgumentList -contains 'config' -or $ArgumentList -contains 'add') {
                    return ''
                }
                if ($ArgumentList -contains 'diff') {
                    $paths = if (
                        $ArgumentList -contains $script:staticBase -and
                        $ArgumentList -contains $script:staticRemote
                    ) {
                        $script:staticRemoteChanged
                    } else {
                        @($script:staticChanged) + @($script:staticExtraChanged)
                    }
                    $text = if (@($paths).Count) {
                        ($paths -join [char] 0) + [char] 0
                    } else {
                        ''
                    }
                    return [pscustomobject]@{ ExitCode = 0; StandardOutput = $text; StandardError = '' }
                }
                if ($ArgumentList -contains 'ls-files') {
                    return [pscustomobject]@{ ExitCode = 0; StandardOutput = ''; StandardError = '' }
                }
                if ($ArgumentList -contains 'commit') {
                    $script:staticHead = '5' * 40
                    return ''
                }
                if ($ArgumentList -contains 'push') {
                    $script:staticPushCount++
                    $exitCode = if ($script:staticPushExitCodes.Count) {
                        $script:staticPushExitCodes.Dequeue()
                    } else {
                        0
                    }
                    $allowFailureRequested = [bool] (
                        Get-Variable -Name AllowFailure -ValueOnly -ErrorAction SilentlyContinue
                    )
                    if ($exitCode -and -not $allowFailureRequested) {
                        throw 'second static push failed'
                    }
                    return [pscustomobject]@{ ExitCode = $exitCode; StandardOutput = ''; StandardError = '' }
                }
                if ($ArgumentList -contains 'fetch') {
                    return ''
                }
                if ($ArgumentList -contains 'merge-base') {
                    return [pscustomobject]@{
                        ExitCode       = $script:staticAncestryExitCode
                        StandardOutput = ''
                        StandardError  = ''
                    }
                }
                if ($ArgumentList -contains 'switch') {
                    $script:staticHead = $script:staticRemote
                    $script:staticImage = $script:staticInitialImage
                    $script:staticChanged = @()
                    return ''
                }
                if ($ArgumentList -contains 'rev-parse') {
                    if ($ArgumentList -contains 'FETCH_HEAD') {
                        return $script:staticRemote
                    }
                    return $script:staticHead
                }
            }

            throw "Unexpected native process: $FilePath $($ArgumentList -join ' ')"
        }
    }

    It 'updates only the fixed staticSites image tag and pushes once' {
        Invoke-StaticSiteUpdate

        $script:staticImage | Should -Be 'build-123'
        Should -Invoke Invoke-NativeProcess -ModuleName GitOpsChartUpdate -Times 1 -ParameterFilter {
            $FilePath -eq 'git' -and $ArgumentList -contains 'push'
        }
        $script:staticPushCount | Should -Be 1
    }

    It 'treats an already-current static-site image as success without mutation' {
        $script:staticImage = $env:INPUT_IMAGE_VERSION

        { Invoke-StaticSiteUpdate } | Should -Not -Throw

        Should -Invoke Invoke-NativeProcess -ModuleName GitOpsChartUpdate -Times 1 -ParameterFilter {
            $FilePath -eq 'helm' -and ($ArgumentList -join ' ') -like 'lint *'
        }
        Should -Invoke Invoke-NativeProcess -ModuleName GitOpsChartUpdate -Times 0 -ParameterFilter {
            $FilePath -eq 'git' -and $ArgumentList -contains 'commit'
        }
    }

    It 'requires the fixed staticSites dependency alias' {
        $script:staticAlias = 'site'

        { Invoke-StaticSiteUpdate } | Should -Throw "*must define alias 'staticSites'*"
    }

    It 'rejects any path outside the fixed static-site values file' {
        $script:staticExtraChanged = @('README.md')

        { Invoke-StaticSiteUpdate } | Should -Throw '*unexpected path: README.md*'

        Should -Invoke Invoke-NativeProcess -ModuleName GitOpsChartUpdate -Times 0 -ParameterFilter {
            $FilePath -eq 'git' -and $ArgumentList -contains 'commit'
        }
    }

    It 'reapplies once after an unrelated concurrent static-site update' {
        $script:staticPushExitCodes.Clear()
        $script:staticPushExitCodes.Enqueue(1)
        $script:staticPushExitCodes.Enqueue(0)
        $script:staticRemote = '6' * 40
        $script:staticRemoteChanged = @('unrelated.yaml')

        Invoke-StaticSiteUpdate

        $script:staticPushCount | Should -Be 2
        Should -Invoke Invoke-NativeProcess -ModuleName GitOpsChartUpdate -Times 1 -ParameterFilter {
            $FilePath -eq 'git' -and $ArgumentList -contains 'switch' -and
            $ArgumentList -contains $script:staticRemote
        }
    }

    It 'fails closed when a concurrent update changes static-site values' {
        $script:staticPushExitCodes.Clear()
        $script:staticPushExitCodes.Enqueue(1)
        $script:staticRemote = '6' * 40
        $script:staticRemoteChanged = @('site/envs/prod/values.yaml')

        { Invoke-StaticSiteUpdate } | Should -Throw '*concurrent update changed protected wrapper state*'

        $script:staticPushCount | Should -Be 1
    }

    It 'fails closed when static-site history diverges' {
        $script:staticPushExitCodes.Clear()
        $script:staticPushExitCodes.Enqueue(1)
        $script:staticRemote = '6' * 40
        $script:staticAncestryExitCode = 1

        { Invoke-StaticSiteUpdate } | Should -Throw '*no longer descends*'

        $script:staticPushCount | Should -Be 1
    }

    It 'propagates a second static-site push failure without forcing' {
        $script:staticPushExitCodes.Clear()
        $script:staticPushExitCodes.Enqueue(1)
        $script:staticPushExitCodes.Enqueue(1)
        $script:staticRemote = '6' * 40
        $script:staticRemoteChanged = @('unrelated.yaml')

        { Invoke-StaticSiteUpdate } | Should -Throw '*second static push failed*'

        $script:staticPushCount | Should -Be 2
        Should -Invoke Invoke-NativeProcess -ModuleName GitOpsChartUpdate -Times 0 -ParameterFilter {
            $FilePath -eq 'git' -and $ArgumentList -contains '--force'
        }
    }
}
