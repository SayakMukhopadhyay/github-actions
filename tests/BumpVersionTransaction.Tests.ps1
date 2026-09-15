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

        function New-GitHubCommitResponse(
            [string] $Oid,
            [bool] $IsValid = $true,
            [string] $State = 'VALID',
            [bool] $WasSignedByGitHub = $true,
            [AllowNull()][string] $BranchOid = $null
        ) {
            if ([string]::IsNullOrEmpty($BranchOid)) {
                $BranchOid = $Oid
            }

            [pscustomobject]@{
                errors = @()
                data   = [pscustomobject]@{
                    createCommitOnBranch = [pscustomobject]@{
                        commit = [pscustomobject]@{
                            oid       = $Oid
                            signature = [pscustomobject]@{
                                isValid           = $IsValid
                                state             = $State
                                wasSignedByGitHub = $WasSignedByGitHub
                            }
                        }
                        ref    = [pscustomobject]@{
                            target = [pscustomobject]@{
                                oid = $BranchOid
                            }
                        }
                    }
                }
            }
        }
    }

    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:repository = New-BumpRepository $root

        $env:GITHUB_WORKSPACE = $script:repository.Work
        $env:GITHUB_REPOSITORY = 'example/project'
        $env:INPUT_TOKEN = 'test-token'
        $env:INPUT_WORKING_DIRECTORY = '.'
        $env:TARGET_REPOSITORY = $env:GITHUB_REPOSITORY
        $env:TARGET_REF = 'main'
        $env:INPUT_GO = 'false'
        $env:INPUT_HELM = 'false'
        $env:NEW_APPLICATION_VERSION = $null
        $env:NEW_CHART_VERSION = $null

        $global:BumpVersionGraphQLRequest = $null
        $global:BumpVersionGraphQLResponse = New-GitHubCommitResponse ('a' * 40)
        Mock Invoke-RestMethod -ModuleName GitTransaction {
            $global:BumpVersionGraphQLRequest = @{
                Method      = $Method
                Uri         = $Uri
                Headers     = $Headers
                ContentType = $ContentType
                Body        = $Body
            }
            $global:BumpVersionGraphQLResponse
        }
    }

    AfterEach {
        Remove-Variable BumpVersionGraphQLRequest -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable BumpVersionGraphQLResponse -Scope Global -ErrorAction SilentlyContinue
    }

    It 'publishes exactly all three authorities atomically for a combined Helm and Go bump' {
        $env:INPUT_GO = 'true'
        $env:INPUT_HELM = 'true'
        $env:NEW_APPLICATION_VERSION = '1.1.0'
        $env:NEW_CHART_VERSION = '1.1.0'

        Set-Content (Join-Path $script:repository.Work 'VERSION') '1.1.0'
        Set-Content (Join-Path $script:repository.Work 'charts/VERSION') '1.1.0'
        Set-Content (Join-Path $script:repository.Work 'charts/Chart.yaml') "version: 1.1.0`nappVersion: 1.1.0"

        Invoke-GitTransaction commit

        $request = $global:BumpVersionGraphQLRequest
        $payload = $request.Body | ConvertFrom-Json
        $input = $payload.variables.input
        $paths = @($input.fileChanges.additions.path)

        $request.Method | Should -Be Post
        $request.Uri | Should -Be 'https://api.github.com/graphql'
        $request.Headers.Authorization | Should -Be 'Bearer test-token'
        $request.ContentType | Should -Be 'application/json'
        $input.branch.repositoryNameWithOwner | Should -Be 'example/project'
        $input.branch.branchName | Should -Be 'main'
        $input.expectedHeadOid | Should -Be $script:repository.Base
        $input.message.headline |
            Should -Be 'feat: bump chart version to 1.1.0 and app version to 1.1.0'
        @($input.PSObject.Properties.Name) |
            Should -Be @('branch', 'expectedHeadOid', 'fileChanges', 'message')
        @($input.message.PSObject.Properties.Name) | Should -Be @('headline')
        $paths.Count | Should -Be 3
        $paths | Should -Contain 'VERSION'
        $paths | Should -Contain 'charts/VERSION'
        $paths | Should -Contain 'charts/Chart.yaml'
        foreach ($addition in $input.fileChanges.additions) {
            $expectedBytes = [IO.File]::ReadAllBytes((Join-Path $script:repository.Work $addition.path))
            $addition.contents | Should -Be ([Convert]::ToBase64String($expectedBytes))
        }
        (Invoke-BumpGit $script:repository.Work @('rev-parse', 'HEAD')) |
            Should -Be $script:repository.Base
    }

    It 'publishes only Helm authorities for a chart-only bump' {
        $env:INPUT_HELM = 'true'
        $env:NEW_CHART_VERSION = '1.1.0'

        Set-Content (Join-Path $script:repository.Work 'charts/VERSION') '1.1.0'
        Set-Content (Join-Path $script:repository.Work 'charts/Chart.yaml') "version: 1.1.0`nappVersion: 1.0.0"

        Invoke-GitTransaction commit

        $input = ($global:BumpVersionGraphQLRequest.Body | ConvertFrom-Json).variables.input
        $paths = @($input.fileChanges.additions.path)

        $paths.Count | Should -Be 2
        $paths | Should -Not -Contain 'VERSION'
        $input.message.headline | Should -Be 'feat: bump chart version to 1.1.0'
    }

    It 'publishes only the application authority for a Go-only bump' {
        $env:INPUT_GO = 'true'
        $env:NEW_APPLICATION_VERSION = '1.1.0'

        Set-Content (Join-Path $script:repository.Work 'VERSION') '1.1.0'

        Invoke-GitTransaction commit

        $input = ($global:BumpVersionGraphQLRequest.Body | ConvertFrom-Json).variables.input
        $paths = @($input.fileChanges.additions.path)

        $paths | Should -Be @('VERSION')
        $input.message.headline | Should -Be 'feat: bump app version to 1.1.0'
    }

    It 'uses the checked-out HEAD and fails closed when GitHub reports a branch race' {
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
        $global:BumpVersionGraphQLResponse = [pscustomobject]@{
            errors = @(
                [pscustomobject]@{
                    message = 'Expected branch to point to the supplied OID.'
                }
            )
            data   = $null
        }

        { Invoke-GitTransaction commit } | Should -Throw '*Expected branch to point*'

        $input = ($global:BumpVersionGraphQLRequest.Body | ConvertFrom-Json).variables.input
        $input.expectedHeadOid | Should -Be $script:repository.Base
        (Invoke-BumpGit $script:repository.Work @('ls-remote', 'origin', 'refs/heads/main')) |
            Should -Match $remoteHead
    }

    It 'fails closed when GitHub does not return a valid GitHub-generated signature' {
        $env:INPUT_GO = 'true'
        $env:NEW_APPLICATION_VERSION = '1.1.0'
        Set-Content (Join-Path $script:repository.Work 'VERSION') '1.1.0'
        $global:BumpVersionGraphQLResponse = New-GitHubCommitResponse `
            -Oid ('b' * 40) `
            -IsValid $false `
            -State 'UNSIGNED' `
            -WasSignedByGitHub $false

        { Invoke-GitTransaction commit } | Should -Throw '*valid GitHub-signed commit*'
    }

    It 'fails closed when the returned branch does not point to the created commit' {
        $env:INPUT_GO = 'true'
        $env:NEW_APPLICATION_VERSION = '1.1.0'
        Set-Content (Join-Path $script:repository.Work 'VERSION') '1.1.0'
        $global:BumpVersionGraphQLResponse = New-GitHubCommitResponse `
            -Oid ('b' * 40) `
            -BranchOid ('c' * 40)

        { Invoke-GitTransaction commit } | Should -Throw '*branch OID*'
    }
}
