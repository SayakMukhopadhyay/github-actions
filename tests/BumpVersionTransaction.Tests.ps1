#requires -Version 7.4

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'bump-version' 'GitTransaction.psm1') -Force
}

Describe 'Version bump Git transaction' {
    BeforeAll {
        function Invoke-BumpGit([string] $Repository, [string[]] $Arguments) {
            & git -C $Repository @Arguments

            if ($LASTEXITCODE -ne 0) {
                throw "git failed: $($Arguments -join ' ')"
            }
        }

        function New-BumpRepository([string] $Root) {
            $remote = Join-Path $Root 'remote.git'
            $work = Join-Path $Root 'work'

            New-Item -ItemType Directory $Root, $work | Out-Null

            Invoke-BumpGit $Root @('init', '--bare', $remote) | Out-Null
            Invoke-BumpGit $work @('init', '--initial-branch=main') | Out-Null
            Invoke-BumpGit $work @('config', 'user.name', 'Pester') | Out-Null
            Invoke-BumpGit $work @('config', 'user.email', 'pester@example.invalid') | Out-Null
            Invoke-BumpGit $work @('config', 'commit.gpgsign', 'false') | Out-Null

            New-Item -ItemType Directory (Join-Path $work 'charts') | Out-Null
            Set-Content (Join-Path $work 'VERSION') '1.0.0'
            Set-Content (Join-Path $work 'charts/VERSION') '1.0.0'
            Set-Content (Join-Path $work 'charts/Chart.yaml') "version: 1.0.0`nappVersion: 1.0.0"

            Invoke-BumpGit $work @('add', '.') | Out-Null
            Invoke-BumpGit $work @('commit', '-m', 'initial') | Out-Null
            Invoke-BumpGit $work @('remote', 'add', 'origin', $remote) | Out-Null
            Invoke-BumpGit $work @('push', 'origin', 'main') | Out-Null

            @{
                Work   = $work
                Remote = $remote
                Base   = Invoke-BumpGit $work @('rev-parse', 'HEAD')
            }
        }
    }

    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:repository = New-BumpRepository $root

        $env:GITHUB_WORKSPACE = $script:repository.Work
        $env:INPUT_WORKING_DIRECTORY = '.'
        $env:TARGET_REF = 'main'
        $env:INPUT_GO = 'false'
        $env:INPUT_HELM = 'false'
        $env:NEW_APPLICATION_VERSION = $null
        $env:NEW_CHART_VERSION = $null
    }

    It 'commits exactly all three authorities for a combined Helm and Go bump' {
        $env:INPUT_GO = 'true'
        $env:INPUT_HELM = 'true'
        $env:NEW_APPLICATION_VERSION = '1.1.0'
        $env:NEW_CHART_VERSION = '1.1.0'

        Set-Content (Join-Path $script:repository.Work 'VERSION') '1.1.0'
        Set-Content (Join-Path $script:repository.Work 'charts/VERSION') '1.1.0'
        Set-Content (Join-Path $script:repository.Work 'charts/Chart.yaml') "version: 1.1.0`nappVersion: 1.1.0"

        Invoke-GitTransaction commit

        $paths = @(
            Invoke-BumpGit $script:repository.Work @('show', '--format=', '--name-only', 'HEAD') |
                Where-Object { $_ }
        )

        $paths.Count | Should -Be 3
        $paths | Should -Contain 'VERSION'
        $paths | Should -Contain 'charts/VERSION'
        $paths | Should -Contain 'charts/Chart.yaml'
    }

    It 'commits only Helm authorities for a chart-only bump' {
        $env:INPUT_HELM = 'true'
        $env:NEW_CHART_VERSION = '1.1.0'

        Set-Content (Join-Path $script:repository.Work 'charts/VERSION') '1.1.0'
        Set-Content (Join-Path $script:repository.Work 'charts/Chart.yaml') "version: 1.1.0`nappVersion: 1.0.0"

        Invoke-GitTransaction commit

        $paths = @(
            Invoke-BumpGit $script:repository.Work @('show', '--format=', '--name-only', 'HEAD') |
                Where-Object { $_ }
        )

        $paths.Count | Should -Be 2
        $paths | Should -Not -Contain 'VERSION'
    }

    It 'commits only the application authority for a Go-only bump' {
        $env:INPUT_GO = 'true'
        $env:NEW_APPLICATION_VERSION = '1.1.0'

        Set-Content (Join-Path $script:repository.Work 'VERSION') '1.1.0'

        Invoke-GitTransaction commit

        $paths = @(
            Invoke-BumpGit $script:repository.Work @('show', '--format=', '--name-only', 'HEAD') |
                Where-Object { $_ }
        )

        $paths | Should -Be @('VERSION')
    }

    It 'does not force through a concurrent remote branch update' {
        $concurrent = Join-Path $TestDrive 'concurrent'

        Invoke-BumpGit $TestDrive @('clone', $script:repository.Remote, $concurrent) | Out-Null
        Invoke-BumpGit $concurrent @('config', 'user.name', 'Concurrent') | Out-Null
        Invoke-BumpGit $concurrent @('config', 'user.email', 'concurrent@example.invalid') | Out-Null
        Invoke-BumpGit $concurrent @('config', 'commit.gpgsign', 'false') | Out-Null
        Invoke-BumpGit $concurrent @('switch', 'main') | Out-Null

        Set-Content (Join-Path $concurrent 'other.txt') other

        Invoke-BumpGit $concurrent @('add', 'other.txt') | Out-Null
        Invoke-BumpGit $concurrent @('commit', '-m', 'concurrent') | Out-Null
        Invoke-BumpGit $concurrent @('push', 'origin', 'main') | Out-Null

        $remoteHead = Invoke-BumpGit $concurrent @('rev-parse', 'HEAD')

        $env:INPUT_GO = 'true'
        $env:NEW_APPLICATION_VERSION = '1.1.0'
        Set-Content (Join-Path $script:repository.Work 'VERSION') '1.1.0'

        { Invoke-GitTransaction commit } | Should -Throw

        (Invoke-BumpGit $script:repository.Work @('ls-remote', 'origin', 'refs/heads/main')) |
            Should -Match $remoteHead
    }
}
