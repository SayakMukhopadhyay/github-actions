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

    It 'treats Buildx exact-reference not-found output as absent' {
        $reference = 'ghcr.io/kode-blox/golfs:build-41abc3e2c2edd0099b5e7b8070d7b86a9da9fea9'
        Mock Invoke-NativeProcess -ModuleName OciArtifactProbe {
            [pscustomobject]@{
                ExitCode       = 1
                StandardOutput = ''
                StandardError  = "ERROR: ${reference}: not found"
            }
        }

        $result = Invoke-OciArtifactProbe docker @(
            'buildx'
            'imagetools'
            'inspect'
            '--format'
            '{{json .Manifest}}'
            $reference
        )

        $result.Exists | Should -BeFalse
    }

    It 'fails closed when Buildx reports not found for a different reference' {
        Mock Invoke-NativeProcess -ModuleName OciArtifactProbe {
            [pscustomobject]@{
                ExitCode       = 1
                StandardOutput = ''
                StandardError  = 'ERROR: ghcr.io/owner/other:tag: not found'
            }
        }

        { Invoke-OciArtifactProbe docker @(
                'buildx'
                'imagetools'
                'inspect'
                '--format'
                '{{json .Manifest}}'
                'ghcr.io/owner/repository:tag'
            ) } | Should -Throw '*OCI artifact probe failed*'
    }

    It 'fails closed when another Docker command reports the exact reference as not found' {
        $reference = 'ghcr.io/owner/repository:tag'
        Mock Invoke-NativeProcess -ModuleName OciArtifactProbe {
            [pscustomobject]@{
                ExitCode       = 1
                StandardOutput = ''
                StandardError  = "ERROR: ${reference}: not found"
            }
        }

        { Invoke-OciArtifactProbe docker @('pull', $reference) } |
            Should -Throw '*OCI artifact probe failed*'
    }

    It 'treats Helm exact-reference not-found output as absent' {
        $reference = 'ghcr.io/kode-blox/charts/golfs:0.0.0-build-' + ('a' * 40)
        Mock Invoke-NativeProcess -ModuleName OciArtifactProbe {
            [pscustomobject]@{
                ExitCode       = 1
                StandardOutput = ''
                StandardError  = "Error: failed to perform `"FetchReference`" on source: ${reference}: not found"
            }
        }

        $result = Invoke-OciArtifactProbe helm @(
            'show'
            'chart'
            'oci://ghcr.io/kode-blox/charts/golfs'
            '--version'
            ('0.0.0-build-' + ('a' * 40))
        )

        $result.Exists | Should -BeFalse
    }

    It 'fails closed when Helm reports not found for a different reference' {
        Mock Invoke-NativeProcess -ModuleName OciArtifactProbe {
            [pscustomobject]@{
                ExitCode       = 1
                StandardOutput = ''
                StandardError  = 'Error: failed to perform "FetchReference" on source: ghcr.io/owner/other:1.2.3: not found'
            }
        }

        { Invoke-OciArtifactProbe helm @(
                'show'
                'chart'
                'oci://ghcr.io/owner/repository'
                '--version'
                '1.2.3'
            ) } | Should -Throw '*OCI artifact probe failed*'
    }

    It 'fails closed when another Helm command reports the exact reference as not found' {
        Mock Invoke-NativeProcess -ModuleName OciArtifactProbe {
            [pscustomobject]@{
                ExitCode       = 1
                StandardOutput = ''
                StandardError  = 'Error: ghcr.io/owner/repository:1.2.3: not found'
            }
        }

        { Invoke-OciArtifactProbe helm @('pull', 'oci://ghcr.io/owner/repository', '--version', '1.2.3') } |
            Should -Throw '*OCI artifact probe failed*'
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
