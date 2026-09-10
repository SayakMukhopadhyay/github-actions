#requires -Version 7.4

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'azure-acr-token' 'AzureAcrToken.psm1') -Force
}

Describe 'Azure ACR token action' {
    BeforeEach {
        $env:GITHUB_OUTPUT = Join-Path $TestDrive 'output'
        Remove-Item -LiteralPath $env:GITHUB_OUTPUT -ErrorAction SilentlyContinue
        $env:INPUT_LOGIN_SERVER = $null
    }

    It 'derives the registry name and suffix from the Andromeda DNL login server' {
        $env:INPUT_LOGIN_SERVER = 'andromeda-dnl.azurecr.io'
        Mock Invoke-NativeProcess -ModuleName AzureAcrToken {
            [pscustomobject]@{
                ExitCode       = 0
                StandardOutput = "secret-token`n"
                StandardError  = ''
            }
        }

        Invoke-AzureAcrTokenAction

        Should -Invoke Invoke-NativeProcess -ModuleName AzureAcrToken -ParameterFilter {
            $FilePath -eq 'az' -and $ArgumentList -join ' ' -match '--name andromeda --suffix dnl'
        }
        (Get-Content -Raw $env:GITHUB_OUTPUT) | Should -Match 'access-token=secret-token'
    }

    It 'normalizes a conventional ACR login server and omits the suffix argument' {
        $env:INPUT_LOGIN_SERVER = 'REGISTRY.azurecr.io'
        Mock Invoke-NativeProcess -ModuleName AzureAcrToken {
            [pscustomobject]@{
                ExitCode       = 0
                StandardOutput = 'token'
                StandardError  = ''
            }
        }

        Invoke-AzureAcrTokenAction

        Should -Invoke Invoke-NativeProcess -ModuleName AzureAcrToken -ParameterFilter {
            $ArgumentList -notcontains '--suffix'
        }
    }

    It 'rejects malformed login servers before invoking Azure CLI' {
        $env:INPUT_LOGIN_SERVER = 'https://registry.azurecr.io/path'
        Mock Invoke-NativeProcess -ModuleName AzureAcrToken {}

        { Invoke-AzureAcrTokenAction } | Should -Throw
        Should -Invoke Invoke-NativeProcess -ModuleName AzureAcrToken -Times 0
    }

    It 'fails without publishing outputs when Azure CLI returns an empty token' {
        $env:INPUT_LOGIN_SERVER = 'registry.azurecr.io'
        Mock Invoke-NativeProcess -ModuleName AzureAcrToken {
            [pscustomobject]@{
                ExitCode       = 0
                StandardOutput = ''
                StandardError  = ''
            }
        }

        { Invoke-AzureAcrTokenAction } | Should -Throw
        (Test-Path $env:GITHUB_OUTPUT) | Should -BeFalse
    }
}
