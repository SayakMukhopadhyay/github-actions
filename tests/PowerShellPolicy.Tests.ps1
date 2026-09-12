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

    It 'standardizes every action-invoked PowerShell entrypoint' {
        $root = Join-Path $PSScriptRoot '..'
        $entrypoints = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $actionFiles = @(& git -C $root ls-files '*/action.yaml' '*/*/action.yaml') |
            ForEach-Object { Get-Item (Join-Path $root $_) }

        foreach ($actionFile in $actionFiles) {
            $source = Get-Content -Raw $actionFile.FullName
            $matches = [regex]::Matches(
                $source,
                '\$env:(?:ACTION_PATH|GITHUB_ACTION_PATH)/(?<path>[^"'']+\.ps1)'
            )
            foreach ($match in $matches) {
                $path = [IO.Path]::GetFullPath((Join-Path $actionFile.Directory.FullName $match.Groups['path'].Value))
                [void] $entrypoints.Add($path)
            }
        }

        $entrypoints.Count | Should -BeGreaterThan 0
        foreach ($entrypoint in $entrypoints) {
            $source = Get-Content -Raw $entrypoint

            (Get-Content $entrypoint -First 1) | Should -Be '#requires -Version 7.4'
            $source | Should -Match 'Import-Module.+ActionRuntime\.psm1'
            $source | Should -Match 'try\s*\{'
            $source | Should -Match 'catch\s*\{'
            $source | Should -Match 'Write-GitHubAnnotation\s+-Message'
            $source | Should -Match 'exit 1'
            $source | Should -Not -Match '::error::'
        }
    }

    It 'retains sanitized create-release diagnostic categories' {
        $root = Join-Path $PSScriptRoot '..'
        (Get-Content -Raw (Join-Path $root 'create-release/collect-git-context.ps1')) |
            Should -Match 'create-release:'
        (Get-Content -Raw (Join-Path $root 'create-release/publish-release.ps1')) |
            Should -Match 'create-release:'
        (Get-Content -Raw (Join-Path $root 'create-release/cleanup-release-session.ps1')) |
            Should -Match 'create-release cleanup:'
    }
}
