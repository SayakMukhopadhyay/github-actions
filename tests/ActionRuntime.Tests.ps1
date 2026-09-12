#requires -Version 7.4

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'ActionRuntime.psm1') -Force
}

Describe 'ActionRuntime' {
    It 'rejects empty and multiline protocol values' {
        { Assert-SingleLine '' input } | Should -Throw
        { Assert-SingleLine "a`nb" input } | Should -Throw
    }

    It 'passes native argument arrays without shell interpretation' {
        $value = Invoke-NativeProcess git @('--version')

        $value | Should -Match '^git version '
    }

    It 'captures exact native failures without exiting PowerShell' {
        $result = Invoke-NativeProcess git @('definitely-not-a-command') -RawOutput -AllowFailure

        $result.ExitCode | Should -Not -Be 0
    }

    It 'throws with the exact native exit code when failure is not allowed' {
        { Invoke-NativeProcess git @('definitely-not-a-command') } | Should -Throw '*exit code*'
    }

    It 'forwards standard input without a temporary shell command' {
        $value = Invoke-NativeProcess pwsh @(
            '-NoProfile',
            '-Command',
            '$input | ForEach-Object { $_.ToUpperInvariant() }'
        ) -StandardInput 'payload'

        $value | Should -Be 'PAYLOAD'
    }

    It 'returns individual lines only when line output is requested' {
        $lines = @(
            Invoke-NativeProcess pwsh @('-NoProfile', '-Command', '"one"; "two"') -LineOutput
        )

        $lines | Should -Be @('one', 'two')
    }

    It 'applies environment overlays only to the child process' {
        $name = 'ACTION_RUNTIME_TEST_VALUE'
        [Environment]::SetEnvironmentVariable($name, $null)

        $output = Invoke-NativeProcess pwsh @(
            '-NoProfile',
            '-Command',
            "[Environment]::GetEnvironmentVariable('$name')"
        ) -Environment @{$name = 'child' }

        $output | Should -Be 'child'
        [Environment]::GetEnvironmentVariable($name) | Should -BeNullOrEmpty
    }

    It 'writes single and multiline GitHub outputs' {
        $env:GITHUB_OUTPUT = Join-Path $TestDrive 'output'

        Write-GitHubOutput alpha beta
        Write-GitHubOutput multi "one`ntwo"

        $text = Get-Content -Raw $env:GITHUB_OUTPUT
        $text | Should -Match 'alpha=beta'
        $text | Should -Match 'multi<<gho_'
    }

    It 'escapes annotation percent signs and newlines before emitting masks' {
        $annotation = Write-GitHubAnnotation warning "100%`rX`ntwo"
        $mask = Add-GitHubMask 'secret'

        $annotation | Should -Be '::warning::100%25%0DX%0Atwo'
        $mask | Should -Be '::add-mask::secret'
    }

    It 'refuses cleanup outside its owned temporary root' {
        $root = Join-Path $TestDrive root
        $outside = Join-Path $TestDrive outside
        New-Item -ItemType Directory $root, $outside | Out-Null

        { Remove-ContainedTemporaryResource $outside $root } | Should -Throw
    }
}
