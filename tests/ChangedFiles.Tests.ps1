#requires -Version 7.4

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'is-file-changed' 'ChangedFiles.psm1') -Force
}

Describe 'Changed-file range validation' {
    BeforeEach {
        $environmentNames = @(
            'BASE_REF'
            'HEAD_REF'
            'BASE_SHA'
            'HEAD_SHA'
            'EVENT_NAME'
            'GITHUB_OUTPUT'
            'GITHUB_WORKSPACE'
            'RUNNER_TEMP'
        )

        foreach ($name in $environmentNames) {
            [Environment]::SetEnvironmentVariable($name, $null)
        }
    }

    It 'requires a push event when explicit refs are omitted' {
        $env:EVENT_NAME = 'pull_request'

        { Invoke-ChangedFilesAction validate } | Should -Throw '*requires a push event*'
    }

    It 'requires explicit refs as a complete pair' {
        $env:BASE_REF = 'main'

        { Invoke-ChangedFilesAction validate } | Should -Throw '*provided together*'
    }

    It 'rejects invalid explicit syntax and zero head IDs' {
        $env:BASE_REF = 'bad ref'
        $env:HEAD_REF = 'main'

        { Invoke-ChangedFilesAction validate } | Should -Throw

        $env:BASE_REF = 'a' * 40
        $env:HEAD_REF = '0' * 40

        { Invoke-ChangedFilesAction validate } | Should -Throw
    }

    It 'accepts full explicit object IDs outside push events' {
        $env:BASE_REF = 'a' * 40
        $env:HEAD_REF = 'b' * 40

        { Invoke-ChangedFilesAction validate } | Should -Not -Throw
    }

    It 'accepts SHA-256 object IDs for repositories using that object format' {
        $env:BASE_REF = 'a' * 64
        $env:HEAD_REF = 'b' * 64

        { Invoke-ChangedFilesAction validate } | Should -Not -Throw
    }

    It 'accepts an initial push zero base and nonzero head' {
        $env:EVENT_NAME = 'push'
        $env:BASE_SHA = '0' * 40
        $env:HEAD_SHA = 'b' * 40

        { Invoke-ChangedFilesAction validate } | Should -Not -Throw
    }

    It 'rejects malformed push endpoints' {
        $env:EVENT_NAME = 'push'
        $env:BASE_SHA = 'bad'
        $env:HEAD_SHA = 'b' * 40

        { Invoke-ChangedFilesAction validate } | Should -Throw '*before SHA*'
    }
}

Describe 'Changed-file collection' {
    BeforeAll {
        function Invoke-TestGit([string] $Repository, [string[]] $Arguments) {
            & git -C $Repository @Arguments

            if ($LASTEXITCODE -ne 0) {
                throw "git failed: $($Arguments -join ' ')"
            }
        }

        function New-TestRepository([string] $Path) {
            New-Item -ItemType Directory -Path $Path | Out-Null

            Invoke-TestGit $Path @('init', '--initial-branch=main') | Out-Null
            Invoke-TestGit $Path @('config', 'user.name', 'Pester') | Out-Null
            Invoke-TestGit $Path @('config', 'user.email', 'pester@example.invalid') | Out-Null
            Invoke-TestGit $Path @('config', 'commit.gpgsign', 'false') | Out-Null

            Set-Content -LiteralPath (Join-Path $Path 'keep.txt') -Value 'initial'
            Set-Content -LiteralPath (Join-Path $Path 'delete.txt') -Value 'delete'

            Invoke-TestGit $Path @('add', 'keep.txt', 'delete.txt') | Out-Null
            Invoke-TestGit $Path @('commit', '-m', 'initial') | Out-Null
            Invoke-TestGit $Path @('rev-parse', 'HEAD')
        }

        function Read-ChangedRecords([string] $OutputFile) {
            $output = Get-Content -Raw -LiteralPath $OutputFile
            $changedFile = ($output -split "`r?`n" | Where-Object { $_ -like 'changed-files=*' }).Substring(14)
            $bytes = [IO.File]::ReadAllBytes($changedFile)

            [Text.Encoding]::UTF8.GetString($bytes).Split(
                [char] 0,
                [StringSplitOptions]::RemoveEmptyEntries
            )
        }
    }

    BeforeEach {
        $environmentNames = @(
            'BASE_REF'
            'HEAD_REF'
            'BASE_SHA'
            'HEAD_SHA'
            'EVENT_NAME'
            'GITHUB_OUTPUT'
            'GITHUB_WORKSPACE'
            'RUNNER_TEMP'
        )

        foreach ($name in $environmentNames) {
            [Environment]::SetEnvironmentVariable($name, $null)
        }

        $env:RUNNER_TEMP = $TestDrive
        $env:GITHUB_OUTPUT = Join-Path $TestDrive 'output'

        Remove-Item -LiteralPath $env:GITHUB_OUTPUT -ErrorAction SilentlyContinue
    }

    It 'collects the exact range across multiple commits' {
        $repository = Join-Path $TestDrive 'range'
        $base = New-TestRepository $repository

        Set-Content -LiteralPath (Join-Path $repository 'first.txt') -Value 'one'
        Invoke-TestGit $repository @('add', 'first.txt') | Out-Null
        Invoke-TestGit $repository @('commit', '-m', 'first') | Out-Null

        Set-Content -LiteralPath (Join-Path $repository 'second.txt') -Value 'two'
        Invoke-TestGit $repository @('add', 'second.txt') | Out-Null
        Invoke-TestGit $repository @('commit', '-m', 'second') | Out-Null

        $head = Invoke-TestGit $repository @('rev-parse', 'HEAD')

        $env:GITHUB_WORKSPACE = $repository
        $env:BASE_REF = $base
        $env:HEAD_REF = $head

        Invoke-ChangedFilesAction

        $records = Read-ChangedRecords $env:GITHUB_OUTPUT

        $records | Should -Contain 'first.txt'
        $records | Should -Contain 'second.txt'
        $records | Should -Not -Contain 'keep.txt'
    }

    It 'resolves stable tag names as explicit endpoints' {
        $repository = Join-Path $TestDrive 'tags'
        $base = New-TestRepository $repository

        Invoke-TestGit $repository @('tag', 'baseline') | Out-Null
        Set-Content -LiteralPath (Join-Path $repository 'tagged.txt') -Value 'changed'
        Invoke-TestGit $repository @('add', 'tagged.txt') | Out-Null
        Invoke-TestGit $repository @('commit', '-m', 'tagged') | Out-Null

        $head = Invoke-TestGit $repository @('rev-parse', 'HEAD')

        $env:GITHUB_WORKSPACE = $repository
        $env:BASE_REF = 'baseline'
        $env:HEAD_REF = $head

        Invoke-ChangedFilesAction

        Read-ChangedRecords $env:GITHUB_OUTPUT | Should -Contain 'tagged.txt'
    }

    It 'retains both paths for rename records and the deleted path' {
        $repository = Join-Path $TestDrive 'renames'
        $base = New-TestRepository $repository

        Invoke-TestGit $repository @('mv', 'keep.txt', 'renamed.txt') | Out-Null
        Remove-Item -LiteralPath (Join-Path $repository 'delete.txt')
        Invoke-TestGit $repository @('add', '-u') | Out-Null
        Invoke-TestGit $repository @('commit', '-m', 'rename and delete') | Out-Null

        $head = Invoke-TestGit $repository @('rev-parse', 'HEAD')

        $env:GITHUB_WORKSPACE = $repository
        $env:BASE_REF = $base
        $env:HEAD_REF = $head

        Invoke-ChangedFilesAction

        $records = Read-ChangedRecords $env:GITHUB_OUTPUT

        $records | Should -Contain 'keep.txt'
        $records | Should -Contain 'renamed.txt'
        $records | Should -Contain 'delete.txt'
    }

    It 'uses the empty tree for an initial push' {
        $repository = Join-Path $TestDrive 'initial'
        $head = New-TestRepository $repository

        $env:GITHUB_WORKSPACE = $repository
        $env:EVENT_NAME = 'push'
        $env:BASE_SHA = '0' * 40
        $env:HEAD_SHA = $head

        Invoke-ChangedFilesAction

        Read-ChangedRecords $env:GITHUB_OUTPUT | Should -Contain 'keep.txt'
    }

    It 'reports both paths when Git recognizes a copy' {
        $repository = Join-Path $TestDrive 'copy'
        $base = New-TestRepository $repository

        Copy-Item (Join-Path $repository 'keep.txt') (Join-Path $repository 'copy.txt')
        Invoke-TestGit $repository @('add', 'copy.txt') | Out-Null
        Invoke-TestGit $repository @('commit', '-m', 'copy') | Out-Null

        $head = Invoke-TestGit $repository @('rev-parse', 'HEAD')

        $env:GITHUB_WORKSPACE = $repository
        $env:BASE_REF = $base
        $env:HEAD_REF = $head

        Invoke-ChangedFilesAction

        $records = Read-ChangedRecords $env:GITHUB_OUTPUT

        $records | Should -Contain 'keep.txt'
        $records | Should -Contain 'copy.txt'
    }

    It 'compares unrelated but locally available endpoints without inventing ancestry' {
        $repository = Join-Path $TestDrive 'unrelated'
        $base = New-TestRepository $repository

        Invoke-TestGit $repository @('switch', '--orphan', 'other') | Out-Null
        Set-Content (Join-Path $repository 'unrelated.txt') unrelated
        Invoke-TestGit $repository @('add', '-A') | Out-Null
        Invoke-TestGit $repository @('commit', '-m', 'unrelated') | Out-Null

        $head = Invoke-TestGit $repository @('rev-parse', 'HEAD')

        $env:GITHUB_WORKSPACE = $repository
        $env:BASE_REF = $base
        $env:HEAD_REF = $head

        Invoke-ChangedFilesAction

        Read-ChangedRecords $env:GITHUB_OUTPUT | Should -Contain 'unrelated.txt'
    }

    It 'fails after bounded fetch attempts when an object is unavailable' {
        $env:GITHUB_WORKSPACE = $TestDrive
        $env:BASE_REF = 'a' * 40
        $env:HEAD_REF = 'b' * 40

        Mock Invoke-NativeProcess -ModuleName ChangedFiles {
            [pscustomobject]@{
                ExitCode       = 1
                StandardOutput = ''
                StandardError  = 'missing'
            }
        }

        { Invoke-ChangedFilesAction } | Should -Throw '*after 2 attempts*'
        Should -Invoke Invoke-NativeProcess -ModuleName ChangedFiles -Times 2 -ParameterFilter {
            $ArgumentList -contains 'fetch'
        }
    }
}
