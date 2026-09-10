#requires -Version 7.4

Import-Module (Join-Path $PSScriptRoot 'DependencyConfiguration.psm1') -Force

Test-DependencyConfiguration
