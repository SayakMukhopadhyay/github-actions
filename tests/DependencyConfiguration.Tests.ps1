#requires -Version 7.4

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'checkout-dependencies' 'DependencyConfiguration.psm1') -Force
}

Describe 'Dependency checkout configuration' {
    BeforeEach {
        foreach ($name in 'INPUT_GO_VERSION', 'INPUT_NODE_VERSION', 'INPUT_NODE_VERSION_FILE') {
            [Environment]::SetEnvironmentVariable($name, $null)
        }
    }

    It 'requires at least one ecosystem' {
        { Test-DependencyConfiguration } | Should -Throw '*configure at least one ecosystem*'
    }

    It 'rejects both Node selectors' {
        $env:INPUT_NODE_VERSION = '24'
        $env:INPUT_NODE_VERSION_FILE = '.nvmrc'

        { Test-DependencyConfiguration } | Should -Throw '*mutually exclusive*'
    }

    It 'accepts Go and either Node selector' {
        $env:INPUT_GO_VERSION = '1.27'
        { Test-DependencyConfiguration } | Should -Not -Throw

        $env:INPUT_GO_VERSION = $null
        $env:INPUT_NODE_VERSION = '24'
        { Test-DependencyConfiguration } | Should -Not -Throw

        $env:INPUT_NODE_VERSION = $null
        $env:INPUT_NODE_VERSION_FILE = '.nvmrc'
        { Test-DependencyConfiguration } | Should -Not -Throw
    }
}
