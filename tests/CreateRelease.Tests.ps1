#requires -Version 7.4

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'create-release' 'ReleaseContext.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..' 'create-release' 'ReleasePublisher.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..' 'create-release' 'ReleaseSession.psm1') -Force
}

Describe 'Create-release Git context collection' {
    BeforeAll {
        function Invoke-ReleaseGit([string] $Repository, [string[]] $Arguments) {
            & git -C $Repository @Arguments

            if ($LASTEXITCODE -ne 0) {
                throw "git failed: $($Arguments -join ' ')"
            }
        }

        function New-ReleaseRepository([string] $Path) {
            New-Item -ItemType Directory $Path | Out-Null

            Invoke-ReleaseGit $Path @('init', '--initial-branch=main') | Out-Null
            Invoke-ReleaseGit $Path @('config', 'user.name', 'Pester') | Out-Null
            Invoke-ReleaseGit $Path @('config', 'user.email', 'pester@example.invalid') | Out-Null
            Invoke-ReleaseGit $Path @('config', 'commit.gpgsign', 'false') | Out-Null

            Set-Content (Join-Path $Path 'root.txt') root

            Invoke-ReleaseGit $Path @('add', 'root.txt') | Out-Null
            Invoke-ReleaseGit $Path @('commit', '-m', 'root') | Out-Null

            $Path
        }

        function Add-ReleaseCommit([string] $Repository, [string] $Path, [string] $Subject) {
            $target = Join-Path $Repository $Path
            $parent = Split-Path -Parent $target

            if (-not (Test-Path $parent)) {
                New-Item -ItemType Directory $parent | Out-Null
            }

            Add-Content -LiteralPath $target -Value $Subject
            Invoke-ReleaseGit $Repository @('add', $Path) | Out-Null
            Invoke-ReleaseGit $Repository @('commit', '-m', $Subject) | Out-Null
            Invoke-ReleaseGit $Repository @('rev-parse', 'HEAD')
        }

        function Read-ReleaseOutput([string] $Name) {
            $line = Get-Content $env:GITHUB_OUTPUT |
                Where-Object { $_ -like "$Name=*" } |
                Select-Object -Last 1

            $line.Substring($Name.Length + 1)
        }
    }

    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:repository = New-ReleaseRepository $root

        $env:GITHUB_WORKSPACE = $script:repository
        $env:RUNNER_TEMP = $TestDrive
        $env:GITHUB_OUTPUT = Join-Path $TestDrive 'output'
        $env:TARGET_REPOSITORY = 'owner/repository'
        $env:TARGET_SERVER_URL = 'https://github.com'
        $env:INPUT_PATHSPECS = $null

        Remove-Item $env:GITHUB_OUTPUT -ErrorAction SilentlyContinue
    }

    It 'selects the highest semantic previous tag in the same family' {
        Invoke-ReleaseGit $script:repository @('tag', 'component-v1.2.0') | Out-Null
        Add-ReleaseCommit $script:repository root.txt next | Out-Null
        Invoke-ReleaseGit $script:repository @('tag', 'component-v1.10.0') | Out-Null
        Add-ReleaseCommit $script:repository root.txt target | Out-Null
        Invoke-ReleaseGit $script:repository @('tag', 'component-v1.11.0') | Out-Null

        $env:INPUT_TAG_NAME = 'component-v1.11.0'

        Invoke-CollectReleaseContext

        $facts = Get-Content -Raw (Read-ReleaseOutput facts-file) | ConvertFrom-Json

        $facts.previousTag | Should -Be 'component-v1.10.0'
    }

    It 'supports an initial release with no previous same-family tag' {
        Invoke-ReleaseGit $script:repository @('tag', 'v1.0.0') | Out-Null
        $env:INPUT_TAG_NAME = 'v1.0.0'

        Invoke-CollectReleaseContext

        $facts = Get-Content -Raw (Read-ReleaseOutput facts-file) | ConvertFrom-Json

        $facts.previousTag | Should -BeNullOrEmpty
        $facts.commits.Count | Should -Be 1
    }

    It 'uses native pathspecs to select only matching mainline commits' {
        Invoke-ReleaseGit $script:repository @('tag', 'v1.0.0') | Out-Null
        Add-ReleaseCommit $script:repository src/app.txt app | Out-Null
        Add-ReleaseCommit $script:repository docs/readme.txt docs | Out-Null
        Invoke-ReleaseGit $script:repository @('tag', 'v1.1.0') | Out-Null

        $env:INPUT_TAG_NAME = 'v1.1.0'
        $env:INPUT_PATHSPECS = 'src/**'

        Invoke-CollectReleaseContext

        $facts = Get-Content -Raw (Read-ReleaseOutput facts-file) | ConvertFrom-Json

        $facts.commits.Count | Should -Be 1
        $facts.commits[0].subject | Should -Be 'app'
    }

    It 'accepts CRLF-delimited include and exclude pathspecs' {
        Invoke-ReleaseGit $script:repository @('tag', 'v1.0.0') | Out-Null
        Add-ReleaseCommit $script:repository src/app.txt app | Out-Null
        Add-ReleaseCommit $script:repository docs/readme.txt docs | Out-Null
        Invoke-ReleaseGit $script:repository @('tag', 'v1.1.0') | Out-Null

        $env:INPUT_TAG_NAME = 'v1.1.0'
        $env:INPUT_PATHSPECS = ":(top)**`r`n:(exclude)docs/**"

        Invoke-CollectReleaseContext

        $facts = Get-Content -Raw (Read-ReleaseOutput facts-file) | ConvertFrom-Json

        $facts.commits.Count | Should -Be 1
        $facts.commits[0].subject | Should -Be 'app'
    }

    It 'accepts a valid pathspec that selects no commits' {
        Invoke-ReleaseGit $script:repository @('tag', 'v1.0.0') | Out-Null
        Add-ReleaseCommit $script:repository root.txt later | Out-Null
        Invoke-ReleaseGit $script:repository @('tag', 'v1.1.0') | Out-Null

        $env:INPUT_TAG_NAME = 'v1.1.0'
        $env:INPUT_PATHSPECS = 'missing/**'

        Invoke-CollectReleaseContext

        $facts = Get-Content -Raw (Read-ReleaseOutput facts-file) | ConvertFrom-Json

        $facts.commits.Count | Should -Be 0
    }

    It 'passes spaces and metacharacters as one literal pathspec argument' {
        Invoke-ReleaseGit $script:repository @('tag', 'v1.0.0') | Out-Null
        Add-ReleaseCommit $script:repository 'folder with space/[literal].txt' literal | Out-Null
        Invoke-ReleaseGit $script:repository @('tag', 'v1.1.0') | Out-Null

        $env:INPUT_TAG_NAME = 'v1.1.0'
        $env:INPUT_PATHSPECS = ':(literal)folder with space/[literal].txt'

        Invoke-CollectReleaseContext

        $facts = Get-Content -Raw (Read-ReleaseOutput facts-file) | ConvertFrom-Json

        $facts.commits.Count | Should -Be 1
    }

    It 'rejects internal empty and no-pathspec sentinel lines' {
        Invoke-ReleaseGit $script:repository @('tag', 'v1.0.0') | Out-Null
        $env:INPUT_TAG_NAME = 'v1.0.0'

        $env:INPUT_PATHSPECS = "src`n`ndocs"
        { Invoke-CollectReleaseContext } | Should -Throw '*empty lines*'

        $env:INPUT_PATHSPECS = ':'
        { Invoke-CollectReleaseContext } | Should -Throw '*no-pathspec sentinel*'
    }

    It 'rejects a checkout that does not match the requested tag' {
        Invoke-ReleaseGit $script:repository @('tag', 'v1.0.0') | Out-Null
        Add-ReleaseCommit $script:repository root.txt later | Out-Null

        $env:INPUT_TAG_NAME = 'v1.0.0'

        { Invoke-CollectReleaseContext } | Should -Throw '*HEAD does not match*'
    }

    It 'rejects a noncanonical semantic version suffix' {
        Invoke-ReleaseGit $script:repository @('tag', 'v01.0.0') | Out-Null
        $env:INPUT_TAG_NAME = 'v01.0.0'

        { Invoke-CollectReleaseContext } | Should -Throw '*canonical*'
    }

    It 'rejects the semantic predecessor when it is outside first-parent history' {
        Invoke-ReleaseGit $script:repository @('switch', '-c', 'side') | Out-Null
        Add-ReleaseCommit $script:repository side.txt side | Out-Null
        Invoke-ReleaseGit $script:repository @('tag', 'v1.1.0') | Out-Null
        Invoke-ReleaseGit $script:repository @('switch', 'main') | Out-Null
        Add-ReleaseCommit $script:repository main.txt target | Out-Null
        Invoke-ReleaseGit $script:repository @('tag', 'v1.2.0') | Out-Null

        $env:INPUT_TAG_NAME = 'v1.2.0'

        { Invoke-CollectReleaseContext } | Should -Throw '*first-parent history*'
    }

    It 'records annotated tag objects separately from their commits' {
        Invoke-ReleaseGit $script:repository @('tag', '-a', 'v1.0.0', '-m', 'annotated') | Out-Null
        $env:INPUT_TAG_NAME = 'v1.0.0'

        Invoke-CollectReleaseContext

        $facts = Get-Content -Raw (Read-ReleaseOutput facts-file) | ConvertFrom-Json

        $facts.targetObject | Should -Not -Be $facts.targetCommit
    }

    It 'keeps only the latest 48 commit records and reports omissions' {
        Invoke-ReleaseGit $script:repository @('tag', 'v1.0.0') | Out-Null

        foreach ($index in 1..50) {
            Add-ReleaseCommit $script:repository root.txt "commit $index" | Out-Null
        }

        Invoke-ReleaseGit $script:repository @('tag', 'v1.1.0') | Out-Null
        $env:INPUT_TAG_NAME = 'v1.1.0'

        Invoke-CollectReleaseContext

        $facts = Get-Content -Raw (Read-ReleaseOutput facts-file) | ConvertFrom-Json

        $facts.commits.Count | Should -Be 48
        $facts.omittedCommitCount | Should -Be 2
    }
}

Describe 'Create-release publication' {
    BeforeAll {
        function New-NativeResult([int] $ExitCode, [string] $Output, [string] $Error = '') {
            [pscustomobject]@{
                ExitCode       = $ExitCode
                StandardOutput = $Output
                StandardError  = $Error
            }
        }
    }

    BeforeEach {
        $script:target = 'a' * 40
        $script:previousObject = 'b' * 40
        $script:existing = $false
        $script:createSuccess = $true
        $script:concurrent = $false
        $script:moved = $false
        $script:releaseReads = 0
        $script:factsPath = Join-Path $TestDrive 'release-facts.json'
        $script:bodyPath = Join-Path $TestDrive 'release-body.md'

        @{
            schemaVersion      = 1
            repository         = 'owner/repository'
            serverUrl          = 'https://github.com'
            tagName            = 'v1.0.0'
            targetObject       = $script:target
            targetCommit       = $script:target
            previousTag        = $null
            previousObject     = $null
            commits            = @()
            omittedCommitCount = 0
        } |
            ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath $script:factsPath -Encoding utf8NoBOM

        Set-Content -LiteralPath $script:bodyPath -Value 'release body'

        $env:RUNNER_TEMP = $TestDrive
        $env:FACTS_FILE = $script:factsPath
        $env:BODY_FILE = $script:bodyPath
        $env:INPUT_TOKEN = 'token'
        $env:INPUT_RELEASE_NAME = 'Release 1.0.0'
        $env:PUBLISH_MODE = 'publish'
        $env:GITHUB_OUTPUT = Join-Path $TestDrive 'publish-output'

        Remove-Item $env:GITHUB_OUTPUT -ErrorAction SilentlyContinue

        Mock Invoke-NativeProcess -ModuleName ReleasePublisher {
            $endpoint = $ArgumentList[3]

            if ($endpoint -like '*/git/ref/tags/v1.0.0') {
                $objectSha = if ($script:moved) {
                    'c' * 40
                } else {
                    $script:target
                }

                $response = @{
                    ref    = 'refs/tags/v1.0.0'
                    object = @{
                        sha = $objectSha
                    }
                }

                return New-NativeResult 0 ($response | ConvertTo-Json -Depth 3)
            }

            if ($endpoint -like '*/git/ref/tags/v0.9.0') {
                $response = @{
                    ref    = 'refs/tags/v0.9.0'
                    object = @{
                        sha = $script:previousObject
                    }
                }

                return New-NativeResult 0 ($response | ConvertTo-Json -Depth 3)
            }

            if ($endpoint -like '*/releases/tags/*') {
                $script:releaseReads++

                if ($script:existing -or ($script:concurrent -and $script:releaseReads -gt 1)) {
                    $response = @{
                        id         = 17
                        html_url   = 'https://github.com/owner/repository/releases/tag/v1.0.0'
                        upload_url = 'https://uploads.github.com/release/17'
                    }

                    return New-NativeResult 0 ($response | ConvertTo-Json)
                }

                return New-NativeResult 1 '' 'HTTP 404'
            }

            if ($ArgumentList[2] -eq 'POST' -and $script:createSuccess) {
                $response = @{
                    id         = 18
                    html_url   = 'https://github.com/owner/repository/releases/tag/v1.0.0'
                    upload_url = 'https://uploads.github.com/release/18'
                }

                return New-NativeResult 0 ($response | ConvertTo-Json)
            }

            New-NativeResult 1 '' 'HTTP 422'
        }
    }

    It 'returns an existing release without creating another one' {
        $script:existing = $true

        Invoke-PublishRelease

        (Get-Content -Raw $env:GITHUB_OUTPUT) | Should -Match 'release-id=17'
        Should -Invoke Invoke-NativeProcess -ModuleName ReleasePublisher -Times 0 -ParameterFilter {
            $ArgumentList[2] -eq 'POST'
        }
    }

    It 'reports a missing release during preflight without publishing' {
        $env:PUBLISH_MODE = 'check'

        Invoke-PublishRelease

        (Get-Content -Raw $env:GITHUB_OUTPUT) | Should -Match 'release-exists=false'
        Should -Invoke Invoke-NativeProcess -ModuleName ReleasePublisher -Times 0 -ParameterFilter {
            $ArgumentList[2] -eq 'POST'
        }
    }

    It 'creates a release from a bounded request file' {
        Invoke-PublishRelease

        (Get-Content -Raw $env:GITHUB_OUTPUT) | Should -Match 'release-id=18'
        Should -Invoke Invoke-NativeProcess -ModuleName ReleasePublisher -Times 1 -ParameterFilter {
            $ArgumentList[2] -eq 'POST' -and $ArgumentList -contains '--input'
        }
    }

    It 'accepts a concurrently created release after a rejected create' {
        $script:createSuccess = $false
        $script:concurrent = $true

        Invoke-PublishRelease

        (Get-Content -Raw $env:GITHUB_OUTPUT) | Should -Match 'release-id=17'
    }

    It 'fails closed when the target tag object moves' {
        $script:moved = $true

        { Invoke-PublishRelease } | Should -Throw '*remote tag moved*'
        Should -Invoke Invoke-NativeProcess -ModuleName ReleasePublisher -Times 0 -ParameterFilter {
            $ArgumentList[2] -eq 'POST'
        }
    }

    It 'reverifies the previous tag object before publication' {
        $facts = Get-Content -Raw $script:factsPath | ConvertFrom-Json
        $facts.previousTag = 'v0.9.0'
        $facts.previousObject = $script:previousObject
        $facts | ConvertTo-Json -Depth 5 | Set-Content $script:factsPath -Encoding utf8NoBOM

        Invoke-PublishRelease

        Should -Invoke Invoke-NativeProcess -ModuleName ReleasePublisher -ParameterFilter {
            $ArgumentList[3] -like '*/git/ref/tags/v0.9.0'
        }
    }

    It 'rejects malformed GitHub release responses' {
        $script:existing = $true

        Mock Invoke-NativeProcess -ModuleName ReleasePublisher -ParameterFilter {
            $ArgumentList[3] -like '*/releases/tags/*'
        } {
            New-NativeResult 0 '{"id":0}'
        }

        { Invoke-PublishRelease } | Should -Throw '*malformed release details*'
    }

    It 'rejects malformed handoff facts before any remote request' {
        Set-Content $script:factsPath '{}'

        { Invoke-PublishRelease } | Should -Throw '*release facts are malformed*'
        Should -Invoke Invoke-NativeProcess -ModuleName ReleasePublisher -Times 0
    }

    It 'removes only collector-owned session directories' {
        $session = Join-Path $TestDrive 'create-release.abc123'
        New-Item -ItemType Directory $session | Out-Null
        $env:SESSION_DIRECTORY = $session

        Invoke-CleanupReleaseSession

        Test-Path $session | Should -BeFalse

        $outside = Join-Path $TestDrive 'not-owned'
        New-Item -ItemType Directory $outside | Out-Null
        $env:SESSION_DIRECTORY = $outside

        { Invoke-CleanupReleaseSession } | Should -Throw '*not collector-owned*'
    }
}
