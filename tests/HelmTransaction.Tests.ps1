#requires -Version 7.4

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'helm-package-push' 'HelmTransaction.psm1') -Force
}

Describe 'Helm package transaction' {
    BeforeEach {
        $script:chart = Join-Path $TestDrive 'chart'
        New-Item -ItemType Directory $script:chart -Force | Out-Null
        Get-ChildItem $script:chart | Remove-Item -Force

        $script:repositories = Join-Path $TestDrive 'repositories'
        $repositoryRecords = [Text.Encoding]::UTF8.GetBytes("stable`0https://charts.example.com`0")
        [IO.File]::WriteAllBytes($script:repositories, $repositoryRecords)

        $env:GITHUB_WORKSPACE = $TestDrive
        $env:RUNNER_TEMP = $TestDrive
        $env:INPUT_CHART_DIRECTORY = $script:chart
        $env:INPUT_REPOSITORIES_FILE = $script:repositories
        $env:INPUT_CHART_NAME = 'application'
        $env:INPUT_CHART_VERSION = '1.2.3'
        $env:INPUT_APP_VERSION = $null
        $env:INPUT_PUSH = 'false'
        $env:INPUT_REGISTRY = 'ghcr.io'
        $env:INPUT_REPOSITORY = 'owner/charts'
        $env:REPOSITORY_OWNER = 'owner'

        Mock Invoke-NativeProcess -ModuleName HelmTransaction {
            if ($ArgumentList -contains 'package') {
                $package = Join-Path $script:chart "$env:INPUT_CHART_NAME-$env:INPUT_CHART_VERSION.tgz"
                New-Item -ItemType File -Path $package -Force | Out-Null
            }

            ''
        }
        Mock Invoke-OciArtifactProbe -ModuleName HelmTransaction {
            [pscustomobject]@{ Exists = $false; StandardOutput = '' }
        }
    }

    It 'adds HTTP repositories and builds, lints, and packages a stable chart' {
        Invoke-HelmTransaction

        Should -Invoke Invoke-OciArtifactProbe -ModuleName HelmTransaction -Times 0
        Should -Invoke Invoke-NativeProcess -ModuleName HelmTransaction -ParameterFilter {
            ($ArgumentList -join ' ') -eq 'repo add stable https://charts.example.com'
        }
        Should -Invoke Invoke-NativeProcess -ModuleName HelmTransaction -ParameterFilter {
            ($ArgumentList -join ' ') -eq 'dependency build'
        }
        Should -Invoke Invoke-NativeProcess -ModuleName HelmTransaction -ParameterFilter {
            ($ArgumentList -join ' ') -eq 'package . --version 1.2.3'
        }
    }

    It 'preserves a free-form application version as one native argument' {
        $env:INPUT_APP_VERSION = 'release candidate + build'

        Invoke-HelmTransaction

        Should -Invoke Invoke-NativeProcess -ModuleName HelmTransaction -ParameterFilter {
            $ArgumentList[-2] -eq '--app-version' -and
            $ArgumentList[-1] -eq 'release candidate + build'
        }
    }

    It 'accepts the pinned development version shape' {
        $env:INPUT_CHART_VERSION = '0.0.0-build-' + ('a' * 40)

        Invoke-HelmTransaction

        Should -Invoke Invoke-NativeProcess -ModuleName HelmTransaction -ParameterFilter {
            $ArgumentList -contains $env:INPUT_CHART_VERSION
        }
    }

    It 'pushes only when explicitly requested and normalizes the OCI coordinate' {
        $env:INPUT_PUSH = 'true'
        $env:INPUT_REGISTRY = 'GHCR.IO'
        $env:INPUT_REPOSITORY = 'Owner/Charts'

        Invoke-HelmTransaction

        Should -Invoke Invoke-NativeProcess -ModuleName HelmTransaction -ParameterFilter {
            ($ArgumentList -join ' ') -eq 'push application-1.2.3.tgz oci://ghcr.io/owner/charts'
        }
    }

    It 'skips the complete Helm transaction when the exact chart version exists' {
        $env:INPUT_PUSH = 'true'
        Mock Invoke-OciArtifactProbe -ModuleName HelmTransaction {
            [pscustomobject]@{ Exists = $true; StandardOutput = 'chart metadata' }
        }

        Invoke-HelmTransaction

        Should -Invoke Invoke-OciArtifactProbe -ModuleName HelmTransaction -Times 1 -ParameterFilter {
            $FilePath -eq 'helm' -and
            ($ArgumentList -join ' ') -eq 'show chart oci://ghcr.io/owner/charts/application --version 1.2.3'
        }
        Should -Invoke Invoke-NativeProcess -ModuleName HelmTransaction -Times 0
    }

    It 'runs the current transaction once when the exact chart version is absent' {
        $env:INPUT_PUSH = 'true'
        Mock Invoke-OciArtifactProbe -ModuleName HelmTransaction {
            [pscustomobject]@{ Exists = $false; StandardOutput = '' }
        }

        Invoke-HelmTransaction

        Should -Invoke Invoke-NativeProcess -ModuleName HelmTransaction -Times 1 -ParameterFilter {
            ($ArgumentList -join ' ') -eq 'dependency build'
        }
        Should -Invoke Invoke-NativeProcess -ModuleName HelmTransaction -Times 1 -ParameterFilter {
            ($ArgumentList -join ' ') -eq 'lint .'
        }
        Should -Invoke Invoke-NativeProcess -ModuleName HelmTransaction -Times 1 -ParameterFilter {
            ($ArgumentList -join ' ') -eq 'package . --version 1.2.3'
        }
        Should -Invoke Invoke-NativeProcess -ModuleName HelmTransaction -Times 1 -ParameterFilter {
            ($ArgumentList -join ' ') -eq 'push application-1.2.3.tgz oci://ghcr.io/owner/charts'
        }
    }

    It 'does not start the Helm transaction after an ambiguous probe failure' {
        $env:INPUT_PUSH = 'true'
        Mock Invoke-OciArtifactProbe -ModuleName HelmTransaction { throw 'authentication failed' }

        { Invoke-HelmTransaction } | Should -Throw '*authentication failed*'

        Should -Invoke Invoke-NativeProcess -ModuleName HelmTransaction -Times 0
    }

    It 'rejects truncated and unsafe dependency repository records' {
        $truncatedRecord = [Text.Encoding]::UTF8.GetBytes("stable`0")
        [IO.File]::WriteAllBytes($script:repositories, $truncatedRecord)

        { Invoke-HelmTransaction } | Should -Throw '*truncated*'

        $unsafeRecord = [Text.Encoding]::UTF8.GetBytes("-bad`0file:///tmp/chart`0")
        [IO.File]::WriteAllBytes($script:repositories, $unsafeRecord)

        { Invoke-HelmTransaction } | Should -Throw '*unsafe*'
    }

    It 'rejects unsafe chart names and noncanonical versions' {
        $env:INPUT_CHART_NAME = '../chart'
        { Invoke-HelmTransaction } | Should -Throw '*chart-name is unsafe*'

        $env:INPUT_CHART_NAME = 'chart'
        $env:INPUT_CHART_VERSION = '01.2.3'
        { Invoke-HelmTransaction } | Should -Throw '*chart-version is invalid*'
    }

    It 'requires the exact expected package artifact' {
        Mock Invoke-NativeProcess -ModuleName HelmTransaction { '' }

        { Invoke-HelmTransaction } | Should -Throw '*did not create the expected package*'
    }
}
