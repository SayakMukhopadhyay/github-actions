#requires -Version 7.4

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'release-tags' 'ReleaseTags.psm1') -Force
}

Describe 'Release tag transactions' {
    BeforeAll {
        function Invoke-TagGit([string] $Repository, [string[]] $Arguments) {
            & git -C $Repository @Arguments

            if ($LASTEXITCODE -ne 0) {
                throw "git failed: $($Arguments -join ' ')"
            }
        }

        function New-TagRepository([string] $Root) {
            $remote = Join-Path $Root 'remote.git'
            $work = Join-Path $Root 'work'

            New-Item -ItemType Directory -Path $Root, $work | Out-Null

            Invoke-TagGit $Root @('init', '--bare', $remote) | Out-Null
            Invoke-TagGit $work @('init', '--initial-branch=main') | Out-Null
            Invoke-TagGit $work @('config', 'user.name', 'Pester') | Out-Null
            Invoke-TagGit $work @('config', 'user.email', 'pester@example.invalid') | Out-Null
            Invoke-TagGit $work @('config', 'commit.gpgsign', 'false') | Out-Null

            Set-Content (Join-Path $work 'file.txt') one

            Invoke-TagGit $work @('add', 'file.txt') | Out-Null
            Invoke-TagGit $work @('commit', '-m', 'one') | Out-Null
            Invoke-TagGit $work @('remote', 'add', 'origin', $remote) | Out-Null
            Invoke-TagGit $work @('push', 'origin', 'main') | Out-Null

            @{
                Work   = $work
                Remote = $remote
                First  = Invoke-TagGit $work @('rev-parse', 'HEAD')
            }
        }

        function Add-TagCommit($Repository) {
            Add-Content (Join-Path $Repository.Work 'file.txt') two

            Invoke-TagGit $Repository.Work @('add', 'file.txt') | Out-Null
            Invoke-TagGit $Repository.Work @('commit', '-m', 'two') | Out-Null
            Invoke-TagGit $Repository.Work @('push', 'origin', 'main') | Out-Null
            Invoke-TagGit $Repository.Work @('rev-parse', 'HEAD')
        }

        function Push-TestTag($Repository, [string] $Name, [string] $Target, [switch] $Annotated) {
            if ($Annotated) {
                Invoke-TagGit $Repository.Work @('tag', '-a', $Name, $Target, '-m', $Name) | Out-Null
            } else {
                Invoke-TagGit $Repository.Work @('tag', $Name, $Target) | Out-Null
            }

            Invoke-TagGit $Repository.Work @('push', 'origin', "refs/tags/$Name") | Out-Null
        }
    }

    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:repository = New-TagRepository $root

        $env:GITHUB_WORKSPACE = $script:repository.Work
        $env:TARGET_SHA = $script:repository.First
        $env:INPUT_TOKEN = 'token'
        $env:INPUT_TAGS = 'v1'
        $env:INPUT_MODE = 'verify'
        $env:GITHUB_OUTPUT = Join-Path $TestDrive 'output'

        Remove-Item -LiteralPath $env:GITHUB_OUTPUT -ErrorAction SilentlyContinue
    }

    It 'reports false when an existence check finds no tag' {
        $env:INPUT_MODE = 'exists'

        Invoke-ReleaseTags

        (Get-Content -Raw $env:GITHUB_OUTPUT) | Should -Match 'tags-exist=false'
    }

    It 'reports true for an existing lightweight tag at any target' {
        Push-TestTag $script:repository v1 $script:repository.First
        $env:INPUT_MODE = 'exists'

        Invoke-ReleaseTags

        (Get-Content -Raw $env:GITHUB_OUTPUT) | Should -Match 'tags-exist=true'
    }

    It 'reports true for an existing annotated tag at any target' {
        $other = Add-TagCommit $script:repository
        Push-TestTag $script:repository v1 $other -Annotated

        $env:TARGET_SHA = $other
        $env:INPUT_MODE = 'exists'

        Invoke-ReleaseTags

        (Get-Content -Raw $env:GITHUB_OUTPUT) | Should -Match 'tags-exist=true'
    }

    It 'reports false when only part of a requested set exists' {
        Push-TestTag $script:repository v1 $script:repository.First

        $env:INPUT_TAGS = "v1`nv2"
        $env:INPUT_MODE = 'exists'

        Invoke-ReleaseTags

        (Get-Content -Raw $env:GITHUB_OUTPUT) | Should -Match 'tags-exist=false'
    }

    It 'verifies lightweight and annotated tags by peeled commit' {
        Push-TestTag $script:repository v1 $script:repository.First
        Push-TestTag $script:repository v2 $script:repository.First -Annotated

        $env:INPUT_TAGS = "v1`nv2"

        Invoke-ReleaseTags

        (Get-Content -Raw $env:GITHUB_OUTPUT) | Should -Match 'tags-match=true'
    }

    It 'reports false when a requested tag is missing or conflicting' {
        Push-TestTag $script:repository v1 $script:repository.First
        $other = Add-TagCommit $script:repository

        $env:TARGET_SHA = $other
        $env:INPUT_TAGS = "v1`nv2"

        Invoke-ReleaseTags

        (Get-Content -Raw $env:GITHUB_OUTPUT) | Should -Match 'tags-match=false'
    }

    It 'rejects duplicate, empty, and invalid tag input' {
        $env:INPUT_TAGS = "v1`nv1"
        { Invoke-ReleaseTags } | Should -Throw '*duplicate*'

        $env:INPUT_TAGS = "v1`n"
        { Invoke-ReleaseTags } | Should -Throw '*empty*'

        $env:INPUT_TAGS = 'bad tag'
        { Invoke-ReleaseTags } | Should -Throw '*invalid Git tag*'
    }

    It 'rejects an excessive tag set before contacting the remote' {
        $env:INPUT_TAGS = (1..257 | ForEach-Object { "v$_" }) -join "`n"

        { Invoke-ReleaseTags } | Should -Throw '*limit of 256*'
    }

    It 'atomically creates only missing tags while retaining existing matches' {
        Push-TestTag $script:repository v1 $script:repository.First

        $env:INPUT_TAGS = "v1`nv2"
        $env:INPUT_MODE = 'ensure'

        Invoke-ReleaseTags

        (Get-Content -Raw $env:GITHUB_OUTPUT) | Should -Match 'tags-match=true'
        Invoke-TagGit $script:repository.Work @('ls-remote', '--exit-code', 'origin', 'refs/tags/v2') |
            Should -Match $script:repository.First
    }

    It 'is idempotent when every tag already matches' {
        Push-TestTag $script:repository v1 $script:repository.First
        $env:INPUT_MODE = 'ensure'

        Invoke-ReleaseTags

        (Get-Content -Raw $env:GITHUB_OUTPUT) | Should -Match 'tags-match=true'
    }

    It 'refuses to overwrite a competing tag' {
        Push-TestTag $script:repository v1 $script:repository.First
        $other = Add-TagCommit $script:repository

        $env:TARGET_SHA = $other
        $env:INPUT_MODE = 'ensure'

        { Invoke-ReleaseTags } | Should -Throw '*refusing to overwrite*'
    }

    It 'fails closed on malformed remote tag data' {
        Mock Invoke-NativeProcess -ModuleName ReleaseTags {
            if ($ArgumentList -contains 'ls-remote') {
                return [pscustomobject]@{
                    ExitCode       = 0
                    StandardOutput = "not-an-object`trefs/tags/v1"
                    StandardError  = ''
                }
            }

            if ($ArgumentList -contains 'check-ref-format') {
                return [pscustomobject]@{
                    ExitCode       = 0
                    StandardOutput = ''
                    StandardError  = ''
                }
            }

            $env:TARGET_SHA
        }

        { Invoke-ReleaseTags } | Should -Throw '*invalid tag object ID*'
    }

    It 'requires the checkout HEAD to equal the fixed target commit' {
        Add-TagCommit $script:repository | Out-Null
        $env:TARGET_SHA = $script:repository.First

        { Invoke-ReleaseTags } | Should -Throw '*HEAD does not match*'
    }
}
