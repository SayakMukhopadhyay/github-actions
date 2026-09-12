#requires -Version 7.4

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'container-build-push' 'ContainerBuild.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..' 'container-image-inspect' 'ContainerImageInspect.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..' 'container-promote' 'ContainerPromotion.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'ContainerImage.psm1') -Force
}

Describe 'Container action preparation' {
    BeforeEach {
        $environmentVariables = @(
            'INPUT_VERSION'
            'INPUT_COMPONENT'
            'INPUT_REGISTRY'
            'INPUT_IMAGE_REPOSITORY'
            'INPUT_USERNAME'
            'INPUT_PASSWORD'
            'SOURCE_REPOSITORY'
            'IMAGE_REFERENCE'
            'INPUT_SOURCE_DIGEST'
            'INPUT_TAG'
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
    }

    It 'constructs and normalizes a build image reference' {
        $env:INPUT_VERSION = '1.2.3'
        $env:INPUT_COMPONENT = 'API'
        $env:INPUT_REGISTRY = 'GHCR.IO'

        Initialize-ContainerBuild

        (Get-Content -Raw $env:GITHUB_OUTPUT) |
            Should -Match 'image-reference=ghcr.io/owner/repository/api:1.2.3'
    }

    It 'rejects metacharacters and control characters in image coordinates' {
        $env:INPUT_VERSION = '1.0.0'
        $env:INPUT_IMAGE_REPOSITORY = 'owner/repo;echo'

        { Initialize-ContainerBuild } | Should -Throw

        $env:INPUT_IMAGE_REPOSITORY = "owner/repo`nnext"
        { Initialize-ContainerBuild } | Should -Throw
    }

    It 'constructs the same normalized reference for read-only inspection' {
        $env:INPUT_VERSION = 'BUILD-ABCDEF'
        $env:INPUT_COMPONENT = 'API'
        $env:INPUT_REGISTRY = 'GHCR.IO'

        Initialize-ContainerImageInspection

        (Get-Content -Raw $env:GITHUB_OUTPUT) |
            Should -Match 'image-reference=ghcr.io/owner/repository/api:BUILD-ABCDEF'
    }

    It 'requires optional inspection credentials as a pair' {
        $env:INPUT_VERSION = '1.2.3'
        $env:INPUT_USERNAME = 'user'

        { Initialize-ContainerImageInspection } | Should -Throw '*provided together*'

        $env:INPUT_PASSWORD = 'token'
        { Initialize-ContainerImageInspection } | Should -Not -Throw
    }

    It 'returns the existing manifest digest for an exact image reference' {
        $digest = 'sha256:' + ('a' * 64)
        $env:IMAGE_REFERENCE = 'ghcr.io/owner/repository:1.2.3'
        Mock Invoke-OciArtifactProbe -ModuleName ContainerImage {
            [pscustomobject]@{
                Exists         = $true
                StandardOutput = "{`"digest`":`"$digest`"}"
            }
        }

        Write-ContainerImageState

        Should -Invoke Invoke-OciArtifactProbe -ModuleName ContainerImage -Times 1 -ParameterFilter {
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
        Mock Invoke-OciArtifactProbe -ModuleName ContainerImage {
            [pscustomobject]@{ Exists = $false; StandardOutput = '' }
        }

        Write-ContainerImageState

        $output = Get-Content -Raw $env:GITHUB_OUTPUT
        $output | Should -Match 'exists=false'
        $output | Should -Match "image-digest=$([Environment]::NewLine)"
    }

    It 'rejects malformed manifest output from a successful image probe' {
        $env:IMAGE_REFERENCE = 'ghcr.io/owner/repository:1.2.3'
        Mock Invoke-OciArtifactProbe -ModuleName ContainerImage {
            [pscustomobject]@{ Exists = $true; StandardOutput = '{"digest":"invalid"}' }
        }

        { Write-ContainerImageState } | Should -Throw '*valid manifest digest*'
    }

    It 'constructs digest and tag references for promotion' {
        $env:INPUT_SOURCE_DIGEST = 'sha256:' + ('a' * 64)
        $env:INPUT_TAG = '1.2.3'
        $env:INPUT_COMPONENT = 'WEB'

        Initialize-ContainerPromotion

        $output = Get-Content -Raw $env:GITHUB_OUTPUT
        $output | Should -Match 'source-reference=ghcr.io/owner/repository/web@sha256:'
        $output | Should -Match 'target-reference=ghcr.io/owner/repository/web:1.2.3'
    }

    It 'rejects malformed digests and target tags' {
        $env:INPUT_SOURCE_DIGEST = 'sha256:bad'
        $env:INPUT_TAG = 'bad tag'

        { Initialize-ContainerPromotion } | Should -Throw
    }

    It 'uses exactly one direct imagetools command and propagates failures' {
        $env:SOURCE_REFERENCE = 'ghcr.io/owner/repo@sha256:' + ('a' * 64)
        $env:TARGET_REFERENCE = 'ghcr.io/owner/repo:1.0.0'
        Mock Invoke-NativeProcess -ModuleName ContainerPromotion {}

        Invoke-ContainerPromotion

        Should -Invoke Invoke-NativeProcess -ModuleName ContainerPromotion -Times 1 -ParameterFilter {
            $command = $ArgumentList -join ' '
            $expectedCommand = (
                'buildx imagetools create --prefer-index=false ' +
                "--tag $env:TARGET_REFERENCE $env:SOURCE_REFERENCE"
            )

            $FilePath -eq 'docker' -and $command -eq $expectedCommand
        }

        Mock Invoke-NativeProcess -ModuleName ContainerPromotion { throw 'docker failed' }

        { Invoke-ContainerPromotion } | Should -Throw '*docker failed*'
    }
}
