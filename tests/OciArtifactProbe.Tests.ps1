#requires -Version 7.4

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'OciArtifactProbe.psm1') -Force
}

Describe 'OCI artifact existence probe' {
    It 'returns successful output as an existing artifact' {
        Mock Invoke-NativeProcess -ModuleName OciArtifactProbe {
            [pscustomobject]@{
                ExitCode       = 0
                StandardOutput = 'manifest output'
                StandardError  = ''
            }
        }

        $result = Invoke-OciArtifactProbe docker @('manifest', 'inspect', 'example.invalid/image:tag')

        $result.Exists | Should -BeTrue
        $result.StandardOutput | Should -Be 'manifest output'
    }

    It 'treats standard OCI not-found errors as absent' -ForEach @(
        'failed to resolve: MANIFEST_UNKNOWN: manifest unknown'
        'failed to resolve: NAME_UNKNOWN: repository name not known'
    ) {
        Mock Invoke-NativeProcess -ModuleName OciArtifactProbe {
            [pscustomobject]@{
                ExitCode       = 1
                StandardOutput = ''
                StandardError  = $_
            }
        }

        $result = Invoke-OciArtifactProbe helm @('show', 'chart', 'oci://example.invalid/charts/app')

        $result.Exists | Should -BeFalse
    }

    It 'fails closed for authentication, network, and invalid-reference errors' -ForEach @(
        'unauthorized: authentication required'
        'dial tcp: lookup example.invalid: no such host'
        'invalid reference format'
    ) {
        Mock Invoke-NativeProcess -ModuleName OciArtifactProbe {
            [pscustomobject]@{
                ExitCode       = 1
                StandardOutput = ''
                StandardError  = $_
            }
        }

        { Invoke-OciArtifactProbe docker @('manifest', 'inspect', 'example.invalid/image:tag') } |
            Should -Throw '*OCI artifact probe failed*'
    }
}
