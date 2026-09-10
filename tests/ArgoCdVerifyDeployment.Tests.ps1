#requires -Version 7.4

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'argocd-verify-deployment' 'VerifyDeployment.psm1') -Force
}

Describe 'Argo CD deployment verification' {
    BeforeEach {
        $script:expected = 'a' * 40
        $script:revision = $script:expected
        $script:sync = 'Synced'
        $script:health = 'Healthy'
        $script:argoExit = 0
        $script:curlExit = 0

        $env:INPUT_SERVER = 'argocd.example.com'
        $env:INPUT_APPLICATION = 'application'
        $env:INPUT_AUTH_TOKEN = 'secret'
        $env:INPUT_CLOUDFLARE_ACCESS_CLIENT_ID = 'client'
        $env:INPUT_CLOUDFLARE_ACCESS_CLIENT_SECRET = 'client-secret'
        $env:INPUT_EXPECTED_COMMIT_SHA = $script:expected
        $env:INPUT_TIMEOUT_SECONDS = '60'
        $env:ARGOCD_CLI_PATH = 'argocd'
        $env:GITOPS_CHECKOUT_PATH = $TestDrive
        $env:GITHUB_OUTPUT = Join-Path $TestDrive 'output'
        $env:RUNNER_TEMP = $TestDrive
        $env:INPUT_SMOKE_URL = $null

        Remove-Item -LiteralPath $env:GITHUB_OUTPUT -ErrorAction SilentlyContinue

        Mock Invoke-NativeProcess -ModuleName VerifyDeployment {
            if ($FilePath -eq 'argocd') {
                $application = @{
                    status = @{
                        sync   = @{
                            status   = $script:sync
                            revision = $script:revision
                        }
                        health = @{
                            status = $script:health
                        }
                    }
                }

                return [pscustomobject]@{
                    ExitCode       = $script:argoExit
                    StandardOutput = $application | ConvertTo-Json -Depth 5
                    StandardError  = 'wait failed'
                }
            }

            if ($FilePath -eq 'curl') {
                return [pscustomobject]@{
                    ExitCode       = $script:curlExit
                    StandardOutput = ''
                    StandardError  = ''
                }
            }

            if ($ArgumentList -contains 'merge-base') {
                return [pscustomobject]@{
                    ExitCode       = 0
                    StandardOutput = ''
                    StandardError  = ''
                }
            }

            [pscustomobject]@{
                ExitCode       = 0
                StandardOutput = ''
                StandardError  = ''
            }
        }
    }

    It 'accepts the exact synchronized revision and passes secret headers as individual arguments' {
        Invoke-VerifyDeployment

        (Get-Content -Raw $env:GITHUB_OUTPUT) | Should -Match "synchronized-revision=$script:expected"
        Should -Invoke Invoke-NativeProcess -ModuleName VerifyDeployment -ParameterFilter {
            $FilePath -eq 'argocd' -and
            $ArgumentList -contains 'CF-Access-Client-Id: client' -and
            $Environment.ARGOCD_AUTH_TOKEN -eq 'secret'
        }
    }

    It 'accepts a synchronized descendant after Git ancestry verification' {
        $script:revision = 'b' * 40

        Invoke-VerifyDeployment

        Should -Invoke Invoke-NativeProcess -ModuleName VerifyDeployment -ParameterFilter {
            $ArgumentList -contains 'merge-base'
        }
    }

    It 'reports a bounded wait failure without parsing arbitrary output' {
        $script:argoExit = 1

        { Invoke-VerifyDeployment } | Should -Throw '*did not become Synced and Healthy*'
    }

    It 'fails immediately for a degraded application' {
        $script:health = 'Degraded'

        { Invoke-VerifyDeployment } | Should -Throw '*unhealthy*'
    }

    It 'rejects an unrelated synchronized revision' {
        $script:revision = 'b' * 40

        Mock Invoke-NativeProcess -ModuleName VerifyDeployment -ParameterFilter {
            $ArgumentList -contains 'merge-base'
        } {
            [pscustomobject]@{
                ExitCode       = 1
                StandardOutput = ''
                StandardError  = ''
            }
        }

        { Invoke-VerifyDeployment } | Should -Throw '*is not an ancestor*'
    }

    It 'rejects an unavailable synchronized revision' {
        $script:revision = 'b' * 40

        Mock Invoke-NativeProcess -ModuleName VerifyDeployment -ParameterFilter {
            $ArgumentList -contains 'cat-file' -and
            $ArgumentList -contains "$script:revision`^{commit}"
        } {
            [pscustomobject]@{
                ExitCode       = 1
                StandardOutput = ''
                StandardError  = ''
            }
        }

        { Invoke-VerifyDeployment } | Should -Throw '*revision is unavailable*'
    }

    It 'runs an authenticated smoke request without exposing secrets' {
        $env:INPUT_SMOKE_URL = 'https://example.com/health'

        Invoke-VerifyDeployment

        Should -Invoke Invoke-NativeProcess -ModuleName VerifyDeployment -ParameterFilter {
            $FilePath -eq 'curl' -and
            $ArgumentList -contains 'CF-Access-Client-Secret: client-secret'
        }
    }

    It 'propagates authenticated smoke failures' {
        $env:INPUT_SMOKE_URL = 'https://example.com/health'
        $script:curlExit = 22

        { Invoke-VerifyDeployment } | Should -Throw '*smoke test failed*'
    }
}
