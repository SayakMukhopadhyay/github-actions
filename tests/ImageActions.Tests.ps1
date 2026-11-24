#requires -Version 7.4

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'image-build-push' 'ImageBuild.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..' 'image-build-push' 'ImageMetadata.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..' 'image-build-push' 'ImageInspection.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..' 'image-build-push' 'ImagePublicationVerification.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..' 'image-inspect' 'ImageInspect.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..' 'image-promote' 'ImagePromotion.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'ImageReference.psm1') -Force
}

Describe 'Image action preparation' {
    BeforeEach {
        $environmentVariables = @(
            'INPUT_TAG'
            'INPUT_VERSION'
            'INPUT_COMPONENT'
            'INPUT_REGISTRY'
            'INPUT_IMAGE_REPOSITORY'
            'INPUT_PUSH'
            'INPUT_USERNAME'
            'INPUT_PASSWORD'
            'SOURCE_REPOSITORY'
            'SOURCE_REVISION'
            'SOURCE_URL'
            'GITHUB_RUN_ID'
            'GITHUB_RUN_ATTEMPT'
            'GITHUB_ACTION'
            'IMAGE_REFERENCE'
            'INSPECTION_REFERENCE'
            'LABEL_SNAPSHOT'
            'INPUT_SOURCE_DIGEST'
            'GITHUB_OUTPUT'
            'SOURCE_REFERENCE'
            'TARGET_REFERENCE'
        )
        foreach ($name in $environmentVariables) {
            [Environment]::SetEnvironmentVariable($name, $null)
        }

        $env:GITHUB_OUTPUT = Join-Path $TestDrive 'output'
        Remove-Item -LiteralPath $env:GITHUB_OUTPUT -ErrorAction SilentlyContinue
        $env:SOURCE_REPOSITORY = 'Owner/Repository'
        $env:SOURCE_REVISION = '0123456789abcdef0123456789abcdef01234567'
        $env:SOURCE_URL = 'https://github.com/Owner/Repository'
        $env:GITHUB_RUN_ID = '1234'
        $env:GITHUB_RUN_ATTEMPT = '2'
        $env:GITHUB_ACTION = 'image-build-push'
    }

    It 'keeps the build tag separate from the packaged application version' {
        $env:INPUT_TAG = 'build-0123456789abcdef0123456789abcdef01234567'
        $env:INPUT_VERSION = '0.0.1'
        $env:INPUT_COMPONENT = 'API'
        $env:INPUT_REGISTRY = 'GHCR.IO'

        Initialize-ImageBuild

        (Get-Content -Raw $env:GITHUB_OUTPUT) |
            Should -Match 'image-reference=ghcr.io/owner/repository/api:build-0123456789abcdef0123456789abcdef01234567'
        (Get-Content -Raw $env:GITHUB_OUTPUT) |
            Should -Match 'inspection-reference=image-build-push-inspection:[0-9a-f]{24}'
        (Get-Content -Raw $env:GITHUB_OUTPUT) |
            Should -Match 'org.opencontainers.image.revision=0123456789abcdef0123456789abcdef01234567'
        (Get-Content -Raw $env:GITHUB_OUTPUT) |
            Should -Match 'org.opencontainers.image.version=0.0.1'
        (Get-Content -Raw $env:GITHUB_OUTPUT) |
            Should -Not -Match 'org.opencontainers.image.version=build-'
    }

    It 'computes one stable temporary reference and one shared dynamic label set' {
        $env:INPUT_TAG = 'build-abcdef'
        $env:INPUT_VERSION = '0.0.1'
        $env:INPUT_PUSH = 'false'

        Initialize-ImageBuild
        $first = Get-Content -Raw $env:GITHUB_OUTPUT
        Remove-Item -LiteralPath $env:GITHUB_OUTPUT
        Initialize-ImageBuild
        $second = Get-Content -Raw $env:GITHUB_OUTPUT

        ($first | Select-String -Pattern 'inspection-reference=([^\r\n]+)').Matches.Groups[1].Value |
            Should -Be (($second | Select-String -Pattern 'inspection-reference=([^\r\n]+)').Matches.Groups[1].Value)
        ($first | Select-String -Pattern 'org.opencontainers.image.created=([^\r\n]+)').Matches.Count |
            Should -Be 1
    }

    It 'converts only allowlisted OCI labels with the correct annotation scope' {
        $annotations = ConvertTo-ImageAnnotations -Labels ([ordered]@{
                'org.opencontainers.image.title'       = 'Package=service'
                'org.opencontainers.image.description' = 'Resolved from the image'
                'org.opencontainers.image.version'     = '0.0.1'
                'org.opencontainers.image.base.name'   = 'ghcr.io/example/base:1'
                'org.opencontainers.image.ref.name'    = 'layout-only'
                'unrelated.example/inherited'          = 'not published as an annotation'
            })

        $annotations -split "`n" | Should -Be @(
            'index,manifest:org.opencontainers.image.version=0.0.1'
            'index,manifest:org.opencontainers.image.title=Package=service'
            'index,manifest:org.opencontainers.image.description=Resolved from the image'
            'manifest:org.opencontainers.image.base.name=ghcr.io/example/base:1'
        )
        $annotations | Should -Not -Match 'unrelated'
        $annotations | Should -Not -Match 'ref\.name'
    }

    It 'fails closed when an allowlisted label cannot be represented as one annotation line' {
        { ConvertTo-ImageAnnotations -Labels @{
                'org.opencontainers.image.title' = "first`nsecond"
            } } | Should -Throw '*control or separator*'
        { ConvertTo-ImageAnnotations -Labels @{
                'org.opencontainers.image.title' = ' padded '
            } } | Should -Throw '*leading or trailing whitespace*'
    }

    It 'reads the completed local image configuration without parsing the Dockerfile' {
        $env:INSPECTION_REFERENCE = 'image-build-push-inspection:abcdef'
        Mock Invoke-NativeProcess -ModuleName ImageInspection {
            '{"Id":"sha256:abc","Os":"linux","Architecture":"amd64","Config":{"Labels":{"org.opencontainers.image.created":"2026-09-14T00:00:00Z","org.opencontainers.image.title":"Fixture=API","inherited.example/value":"kept"}}}'
        }

        Read-LocalImageMetadata

        Should -Invoke Invoke-NativeProcess -ModuleName ImageInspection -Times 1 -ParameterFilter {
            $FilePath -eq 'docker' -and
            ($ArgumentList -join ' ') -eq 'image inspect --format {{json .}} image-build-push-inspection:abcdef'
        }
        $output = Get-Content -Raw $env:GITHUB_OUTPUT
        $output | Should -Match 'org.opencontainers.image.created=2026-09-14T00:00:00Z'
        $output | Should -Match 'index,manifest:org.opencontainers.image.title=Fixture=API'
        $output | Should -Match 'label-snapshot=[A-Za-z0-9+/=]+'
    }

    It 'rejects malformed or ambiguous local Docker inspection results' {
        $env:INSPECTION_REFERENCE = 'image-build-push-inspection:abcdef'
        Mock Invoke-NativeProcess -ModuleName ImageInspection { '[]' }

        { Read-LocalImageMetadata } | Should -Throw '*must be one JSON object*'

        Mock Invoke-NativeProcess -ModuleName ImageInspection {
            '{"Os":"linux","Architecture":"amd64","Config":{"Labels":{"org.opencontainers.image.title":42}}}'
        }
        { Read-LocalImageMetadata } | Should -Throw '*names and values must be strings*'
    }

    It 'verifies final index and manifest annotations and the complete platform label snapshot' {
        $labels = [ordered]@{
            'inherited.example/value'              = 'kept'
            'org.opencontainers.image.base.name'   = 'ghcr.io/example/base:1'
            'org.opencontainers.image.description' = 'Fixture=API'
            'org.opencontainers.image.title'       = 'Fixture'
        }
        $env:LABEL_SNAPSHOT = ConvertTo-LabelSnapshot $labels linux amd64
        $env:IMAGE_REFERENCE = 'ghcr.io/owner/repository:1.2.3'
        $digest = 'sha256:' + ('a' * 64)
        $attestationDigest = 'sha256:' + ('b' * 64)
        Mock Invoke-NativeProcess -ModuleName ImagePublicationVerification {
            $command = $ArgumentList -join ' '
            if ($command -eq "buildx imagetools inspect --raw $env:IMAGE_REFERENCE") {
                return (@{
                        schemaVersion = 2
                        mediaType     = 'application/vnd.oci.image.index.v1+json'
                        annotations   = @{
                            'org.opencontainers.image.description' = 'Fixture=API'
                            'org.opencontainers.image.title'       = 'Fixture'
                        }
                        manifests     = @(
                            @{ digest = $digest; platform = @{ os = 'linux'; architecture = 'amd64' } }
                            @{
                                digest      = $attestationDigest
                                platform    = @{ os = 'unknown'; architecture = 'unknown' }
                                annotations = @{
                                    'vnd.docker.reference.type'   = 'attestation-manifest'
                                    'vnd.docker.reference.digest' = $digest
                                }
                            }
                        )
                    } | ConvertTo-Json -Compress -Depth 20)
            }
            if ($command -eq "buildx imagetools inspect --raw $env:IMAGE_REFERENCE@$digest") {
                return (@{
                        schemaVersion = 2
                        annotations   = @{
                            'org.opencontainers.image.description' = 'Fixture=API'
                            'org.opencontainers.image.title'       = 'Fixture'
                            'org.opencontainers.image.base.name'   = 'ghcr.io/example/base:1'
                        }
                    } | ConvertTo-Json -Compress -Depth 20)
            }
            if ($command -eq "buildx imagetools inspect --raw $env:IMAGE_REFERENCE@$attestationDigest") {
                return (@{
                        artifactType = 'application/vnd.docker.attestation.manifest.v1+json'
                        config       = @{ mediaType = 'application/vnd.oci.empty.v1+json' }
                        subject      = @{ digest = $digest }
                        layers       = @(
                            @{
                                mediaType   = 'application/vnd.in-toto+json'
                                digest      = ('sha256:' + ('c' * 64))
                                annotations = @{
                                    'in-toto.io/predicate-type' = 'https://slsa.dev/provenance/v1'
                                }
                            }
                        )
                    } | ConvertTo-Json -Compress -Depth 20)
            }
            if ($command -match '--format \{\{json \.Image\}\}') {
                return (@{
                        os           = 'linux'
                        architecture = 'amd64'
                        config       = @{ Labels = $labels }
                    } | ConvertTo-Json -Compress -Depth 20)
            }
            throw "unexpected command: $command"
        }

        { Confirm-PublishedImageMetadata } | Should -Not -Throw
        Should -Invoke Invoke-NativeProcess -ModuleName ImagePublicationVerification -Times 4
    }

    It 'fails closed on a second runnable manifest' {
        $labels = [ordered]@{ 'org.opencontainers.image.title' = 'Fixture' }
        $env:LABEL_SNAPSHOT = ConvertTo-LabelSnapshot $labels linux amd64
        $env:IMAGE_REFERENCE = 'ghcr.io/owner/repository:1.2.3'
        $digest = 'sha256:' + ('a' * 64)
        Mock Invoke-NativeProcess -ModuleName ImagePublicationVerification {
            (@{
                mediaType   = 'application/vnd.oci.image.index.v1+json'
                annotations = @{ 'org.opencontainers.image.title' = 'Fixture' }
                manifests   = @(
                    @{ digest = $digest; platform = @{ os = 'linux'; architecture = 'amd64' } }
                    @{ digest = ('sha256:' + ('b' * 64)); platform = @{ os = 'linux'; architecture = 'arm64' } }
                )
            } | ConvertTo-Json -Compress -Depth 20)
        }

        { Confirm-PublishedImageMetadata } | Should -Throw '*exactly one runnable*'
    }

    It 'fails closed when the final platform configuration differs from the probe snapshot' {
        $labels = [ordered]@{ 'org.opencontainers.image.title' = 'Fixture' }
        $env:LABEL_SNAPSHOT = ConvertTo-LabelSnapshot $labels linux amd64
        $env:IMAGE_REFERENCE = 'ghcr.io/owner/repository:1.2.3'
        $digest = 'sha256:' + ('a' * 64)
        $attestationDigest = 'sha256:' + ('b' * 64)
        Mock Invoke-NativeProcess -ModuleName ImagePublicationVerification {
            $command = $ArgumentList -join ' '
            if ($command -eq "buildx imagetools inspect --raw $env:IMAGE_REFERENCE") {
                return (@{
                        mediaType   = 'application/vnd.oci.image.index.v1+json'
                        annotations = @{ 'org.opencontainers.image.title' = 'Fixture' }
                        manifests   = @(
                            @{ digest = $digest; platform = @{ os = 'linux'; architecture = 'amd64' } }
                            @{
                                digest      = $attestationDigest
                                platform    = @{ os = 'unknown'; architecture = 'unknown' }
                                annotations = @{
                                    'vnd.docker.reference.type'   = 'attestation-manifest'
                                    'vnd.docker.reference.digest' = $digest
                                }
                            }
                        )
                    } | ConvertTo-Json -Compress -Depth 20)
            }
            if ($command -eq "buildx imagetools inspect --raw $env:IMAGE_REFERENCE@$digest") {
                return (@{
                        annotations = @{ 'org.opencontainers.image.title' = 'Fixture' }
                    } | ConvertTo-Json -Compress -Depth 20)
            }
            if ($command -eq "buildx imagetools inspect --raw $env:IMAGE_REFERENCE@$attestationDigest") {
                return (@{
                        artifactType = 'application/vnd.docker.attestation.manifest.v1+json'
                        config       = @{ mediaType = 'application/vnd.oci.empty.v1+json' }
                        subject      = @{ digest = $digest }
                        layers       = @(
                            @{
                                mediaType   = 'application/vnd.in-toto+json'
                                digest      = ('sha256:' + ('c' * 64))
                                annotations = @{
                                    'in-toto.io/predicate-type' = 'https://slsa.dev/provenance/v0.2'
                                }
                            }
                        )
                    } | ConvertTo-Json -Compress -Depth 20)
            }
            return (@{
                    config = @{ Labels = @{ 'org.opencontainers.image.title' = 'Changed' } }
                } | ConvertTo-Json -Compress -Depth 20)
        }

        { Confirm-PublishedImageMetadata } | Should -Throw '*label snapshot*'
    }

    It 'removes only the exact local inspection tag and tolerates an absent partial build result' {
        $env:INSPECTION_REFERENCE = 'image-build-push-inspection:abcdef'
        Mock Invoke-NativeProcess -ModuleName ImageInspection {
            [pscustomobject]@{ ExitCode = 1; StandardOutput = ''; StandardError = 'No such image' }
        }

        { Remove-LocalInspectionImage } | Should -Not -Throw
        Should -Invoke Invoke-NativeProcess -ModuleName ImageInspection -Times 1 -ParameterFilter {
            $FilePath -eq 'docker' -and
            ($ArgumentList -join ' ') -eq 'image rm --force image-build-push-inspection:abcdef' -and
            $AllowFailure
        }
    }

    It 'enforces build credentials according to push mode' {
        $env:INPUT_TAG = 'build-abcdef'
        $env:INPUT_VERSION = '1.2.3'
        $env:INPUT_PUSH = 'true'

        { Initialize-ImageBuild } | Should -Throw '*both required*'

        $env:INPUT_USERNAME = 'user'
        $env:INPUT_PASSWORD = 'token'
        { Initialize-ImageBuild } | Should -Not -Throw

        $env:INPUT_PUSH = 'false'
        $env:INPUT_PASSWORD = $null
        { Initialize-ImageBuild } | Should -Throw '*provided together*'
    }

    It 'rejects metacharacters and control characters in image coordinates' {
        $env:INPUT_TAG = 'build-abcdef'
        $env:INPUT_VERSION = '1.0.0'
        $env:INPUT_IMAGE_REPOSITORY = 'owner/repo;echo'

        { Initialize-ImageBuild } | Should -Throw

        $env:INPUT_IMAGE_REPOSITORY = "owner/repo`nnext"
        { Initialize-ImageBuild } | Should -Throw
    }

    It 'constructs the same normalized reference for read-only inspection' {
        $env:INPUT_TAG = 'BUILD-ABCDEF'
        $env:INPUT_COMPONENT = 'API'
        $env:INPUT_REGISTRY = 'GHCR.IO'

        Initialize-ImageInspection

        (Get-Content -Raw $env:GITHUB_OUTPUT) |
            Should -Match 'image-reference=ghcr.io/owner/repository/api:BUILD-ABCDEF'
    }

    It 'requires optional inspection credentials as a pair' {
        $env:INPUT_TAG = 'build-abcdef'
        $env:INPUT_USERNAME = 'user'

        { Initialize-ImageInspection } | Should -Throw '*provided together*'

        $env:INPUT_PASSWORD = 'token'
        { Initialize-ImageInspection } | Should -Not -Throw
    }

    It 'returns the existing manifest digest for an exact image reference' {
        $digest = 'sha256:' + ('a' * 64)
        $env:IMAGE_REFERENCE = 'ghcr.io/owner/repository:1.2.3'
        Mock Invoke-OciArtifactProbe -ModuleName ImageReference {
            [pscustomobject]@{
                Exists         = $true
                StandardOutput = "{`"digest`":`"$digest`"}"
            }
        }

        Write-ImageState

        Should -Invoke Invoke-OciArtifactProbe -ModuleName ImageReference -Times 1 -ParameterFilter {
            $FilePath -eq 'docker' -and
            ($ArgumentList -join ' ') -eq (
                'buildx imagetools inspect --format {{json .Manifest}} ' + $env:IMAGE_REFERENCE
            )
        }
        $output = Get-Content -Raw $env:GITHUB_OUTPUT
        $output | Should -Match 'exists=true'
        $output | Should -Match "image-digest=$digest"
    }

    It 'reports an exact image reference as absent without a digest' {
        $env:IMAGE_REFERENCE = 'ghcr.io/owner/repository:1.2.3'
        Mock Invoke-OciArtifactProbe -ModuleName ImageReference {
            [pscustomobject]@{ Exists = $false; StandardOutput = '' }
        }

        Write-ImageState

        $output = Get-Content -Raw $env:GITHUB_OUTPUT
        $output | Should -Match 'exists=false'
        $output | Should -Match "image-digest=$([Environment]::NewLine)"
    }

    It 'rejects malformed manifest output from a successful image probe' {
        $env:IMAGE_REFERENCE = 'ghcr.io/owner/repository:1.2.3'
        Mock Invoke-OciArtifactProbe -ModuleName ImageReference {
            [pscustomobject]@{ Exists = $true; StandardOutput = '{"digest":"invalid"}' }
        }

        { Write-ImageState } | Should -Throw '*valid manifest digest*'
    }

    It 'constructs digest and tag references for promotion' {
        $env:INPUT_SOURCE_DIGEST = 'sha256:' + ('a' * 64)
        $env:INPUT_TAG = '1.2.3'
        $env:INPUT_COMPONENT = 'WEB'
        $env:INPUT_USERNAME = 'user'
        $env:INPUT_PASSWORD = 'token'

        Initialize-ImagePromotion

        $output = Get-Content -Raw $env:GITHUB_OUTPUT
        $output | Should -Match 'source-reference=ghcr.io/owner/repository/web@sha256:'
        $output | Should -Match 'target-reference=ghcr.io/owner/repository/web:1.2.3'
    }

    It 'rejects malformed digests and target tags' {
        $env:INPUT_SOURCE_DIGEST = 'sha256:bad'
        $env:INPUT_TAG = 'bad tag'
        $env:INPUT_USERNAME = 'user'
        $env:INPUT_PASSWORD = 'token'

        { Initialize-ImagePromotion } | Should -Throw
    }

    It 'requires promotion credentials before constructing references' {
        $env:INPUT_SOURCE_DIGEST = 'sha256:' + ('a' * 64)
        $env:INPUT_TAG = '1.2.3'

        { Initialize-ImagePromotion } | Should -Throw '*both required*'
    }

    It 'normalizes identical image coordinates across build, inspection, and promotion' {
        $env:INPUT_TAG = 'BUILD-AbCd'
        $env:INPUT_VERSION = '0.0.1'
        $env:INPUT_SOURCE_DIGEST = 'sha256:' + ('a' * 64)
        $env:INPUT_COMPONENT = 'API'
        $env:INPUT_REGISTRY = 'REGISTRY.Example.COM:5000'
        $env:INPUT_IMAGE_REPOSITORY = 'Owner/Product'

        Initialize-ImageBuild
        $buildReference = (Get-Content $env:GITHUB_OUTPUT | Where-Object { $_ -like 'image-reference=*' }) -replace '^image-reference=', ''

        Remove-Item -LiteralPath $env:GITHUB_OUTPUT
        Initialize-ImageInspection
        $inspectionReference = (Get-Content $env:GITHUB_OUTPUT | Where-Object { $_ -like 'image-reference=*' }) -replace '^image-reference=', ''

        Remove-Item -LiteralPath $env:GITHUB_OUTPUT
        $env:INPUT_USERNAME = 'user'
        $env:INPUT_PASSWORD = 'token'
        Initialize-ImagePromotion
        $promotionReference = (Get-Content $env:GITHUB_OUTPUT | Where-Object { $_ -like 'target-reference=*' }) -replace '^target-reference=', ''

        $buildReference | Should -Be 'registry.example.com:5000/owner/product/api:BUILD-AbCd'
        $inspectionReference | Should -Be $buildReference
        $promotionReference | Should -Be $buildReference
    }

    It 'uses exactly one direct imagetools source for an index-preserving promotion and propagates failures' {
        $env:SOURCE_REFERENCE = 'ghcr.io/owner/repo@sha256:' + ('a' * 64)
        $env:TARGET_REFERENCE = 'ghcr.io/owner/repo:1.0.0'
        Mock Invoke-NativeProcess -ModuleName ImagePromotion {}

        Invoke-ImagePromotion

        Should -Invoke Invoke-NativeProcess -ModuleName ImagePromotion -Times 1 -ParameterFilter {
            $command = $ArgumentList -join ' '
            $expectedCommand = (
                'buildx imagetools create --prefer-index=false ' +
                "--tag $env:TARGET_REFERENCE $env:SOURCE_REFERENCE"
            )

            $FilePath -eq 'docker' -and $command -eq $expectedCommand
        }

        Mock Invoke-NativeProcess -ModuleName ImagePromotion { throw 'docker failed' }

        { Invoke-ImagePromotion } | Should -Throw '*docker failed*'
    }
}

Describe 'Image action entrypoints' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'ActionRuntime.psm1') -Force
    }

    It 'preserves the original probe failure in the GitHub annotation' {
        $entrypoint = Join-Path $PSScriptRoot '..' 'image-build-push' 'probe-image.ps1'
        $result = Invoke-NativeProcess pwsh @('-NoProfile', '-File', $entrypoint) `
            -Environment @{
            IMAGE_REFERENCE = ''
            GITHUB_OUTPUT   = Join-Path $TestDrive 'entrypoint-output'
        } -RawOutput -AllowFailure

        $diagnostic = "$($result.StandardOutput)`n$($result.StandardError)"
        $result.ExitCode | Should -Be 1
        $diagnostic | Should -Match '::error::image-reference must be a non-empty single-line value'
        $diagnostic | Should -Not -Match "The term 'Write-GitHubAnnotation' is not recognized"
    }
}
