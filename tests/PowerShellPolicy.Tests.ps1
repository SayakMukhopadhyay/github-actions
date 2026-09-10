#requires -Version 7.4

Describe 'PowerShell migration policy' {
    It 'has no tracked Bash or Bats files' {
        $root = Join-Path $PSScriptRoot '..'
        $tracked = @(& git -C $root ls-files | Where-Object { Test-Path (Join-Path $root $_) })

        @($tracked | Where-Object { $_ -match '\.(sh|bash|bats)$' }) | Should -BeNullOrEmpty
    }

    It 'uses explicit pwsh for every maintained run step' {
        $root = Join-Path $PSScriptRoot '..'
        $files = @(& git -C $root ls-files '*.yaml' | Where-Object { Test-Path (Join-Path $root $_) })

        foreach ($file in $files) {
            $text = Get-Content -Raw (Join-Path $root $file)

            $text | Should -Not -Match 'shell:\s*bash'
            $text | Should -Not -Match '#!/usr/bin/env bash'
        }
    }

    It 'requires PowerShell 7.4 in maintained scripts' {
        $root = Join-Path $PSScriptRoot '..'
        $scripts = @(& git -C $root ls-files '*.ps1' '*.psm1' | Where-Object { Test-Path (Join-Path $root $_) })
        $scripts += @(
            Get-ChildItem $root -Depth 2 -Include *.ps1, *.psm1 |
                Where-Object { $_.FullName -notmatch '[\\/](\.tools|node_modules)[\\/]' } |
                ForEach-Object FullName
        )

        foreach ($script in $scripts) {
            $path = if ([IO.Path]::IsPathRooted($script)) {
                $script
            } else {
                Join-Path $root $script
            }

            (Get-Content $path -First 1) | Should -Be '#requires -Version 7.4'
        }
    }
}
