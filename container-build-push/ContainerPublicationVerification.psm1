#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'ActionRuntime.psm1')
Import-Module (Join-Path $PSScriptRoot 'ContainerMetadata.psm1')

function Confirm-PublishedImageMetadata {
    $reference = Assert-SingleLine -Value $env:IMAGE_REFERENCE -Name 'image-reference'
    $snapshot = ConvertFrom-LabelSnapshot -Snapshot $env:LABEL_SNAPSHOT
    $rootJson = Invoke-NativeProcess docker @('buildx', 'imagetools', 'inspect', '--raw', $reference)
    $root = ConvertFrom-RequiredJsonObject -Json $rootJson -Description 'published image index inspection'
    if ($root.mediaType -ne 'application/vnd.oci.image.index.v1+json') {
        throw 'published image must be an OCI image index so package annotations and provenance are preserved'
    }
    Assert-ExpectedAnnotations -ExpectedLabels $snapshot.Labels -ActualAnnotations $root.annotations -Level Index

    $manifests = @(Get-RequiredDictionaryValue $root manifests 'published image index inspection')
    $runnable = @(
        $manifests | Where-Object {
            $_ -is [System.Collections.IDictionary] -and
            $_.platform -is [System.Collections.IDictionary] -and
            $_.platform.os -ne 'unknown' -and
            $_.platform.architecture -ne 'unknown'
        }
    )
    if ($runnable.Count -ne 1) {
        throw "published image index must contain exactly one runnable platform manifest; found $($runnable.Count)"
    }
    $manifestDescriptor = $runnable[0]
    $publishedVariant = if ($manifestDescriptor.platform.Contains('variant')) {
        $manifestDescriptor.platform.variant
    } else {
        ''
    }
    if (
        $manifestDescriptor.platform.os -cne $snapshot.OperatingSystem -or
        $manifestDescriptor.platform.architecture -cne $snapshot.Architecture -or
        $publishedVariant -cne $snapshot.Variant
    ) {
        throw 'published runnable platform does not match the inspected local image platform'
    }
    if ($manifestDescriptor.digest -notmatch '^sha256:[0-9a-f]{64}$') {
        throw 'published runnable platform manifest has an invalid digest'
    }

    $attestationDescriptors = @(
        $manifests | Where-Object {
            $_ -is [System.Collections.IDictionary] -and
            $_.platform -is [System.Collections.IDictionary] -and
            $_.platform.os -eq 'unknown' -and
            $_.platform.architecture -eq 'unknown' -and
            $_.annotations -is [System.Collections.IDictionary] -and
            $_.annotations['vnd.docker.reference.type'] -eq 'attestation-manifest' -and
            $_.annotations['vnd.docker.reference.digest'] -ceq $manifestDescriptor.digest
        }
    )
    if ($attestationDescriptors.Count -ne 1) {
        throw "published image index must contain exactly one attestation manifest for the runnable platform; found $($attestationDescriptors.Count)"
    }
    $attestationDescriptor = $attestationDescriptors[0]
    if ($attestationDescriptor.digest -notmatch '^sha256:[0-9a-f]{64}$') {
        throw 'published attestation manifest has an invalid digest'
    }

    $manifestReference = "$reference@$($manifestDescriptor.digest)"
    $manifestJson = Invoke-NativeProcess docker @('buildx', 'imagetools', 'inspect', '--raw', $manifestReference)
    $manifest = ConvertFrom-RequiredJsonObject -Json $manifestJson -Description 'published platform manifest inspection'
    Assert-ExpectedAnnotations `
        -ExpectedLabels $snapshot.Labels `
        -ActualAnnotations $manifest.annotations `
        -Level Manifest

    $attestationReference = "$reference@$($attestationDescriptor.digest)"
    $attestationJson = Invoke-NativeProcess docker @('buildx', 'imagetools', 'inspect', '--raw', $attestationReference)
    $attestation = ConvertFrom-RequiredJsonObject `
        -Json $attestationJson `
        -Description 'published provenance attestation manifest inspection'
    if ($attestation.artifactType -ne 'application/vnd.docker.attestation.manifest.v1+json') {
        throw 'published provenance must use the Docker OCI attestation manifest artifact type'
    }
    $subject = Get-RequiredDictionaryValue $attestation subject 'published provenance attestation manifest inspection'
    if ($subject -isnot [System.Collections.IDictionary] -or $subject.digest -cne $manifestDescriptor.digest) {
        throw 'published provenance attestation subject does not match the runnable platform manifest'
    }
    $attestationConfig = Get-RequiredDictionaryValue `
        $attestation `
        config `
        'published provenance attestation manifest inspection'
    if (
        $attestationConfig -isnot [System.Collections.IDictionary] -or
        $attestationConfig.mediaType -ne 'application/vnd.oci.empty.v1+json'
    ) {
        throw 'published provenance attestation must use the OCI empty configuration descriptor'
    }
    $attestationLayers = @(Get-RequiredDictionaryValue $attestation layers 'published provenance attestation manifest inspection')
    $provenanceLayers = @(
        $attestationLayers | Where-Object {
            $_ -is [System.Collections.IDictionary] -and
            $_.mediaType -eq 'application/vnd.in-toto+json' -and
            $_.digest -match '^sha256:[0-9a-f]{64}$' -and
            $_.annotations -is [System.Collections.IDictionary] -and
            $_.annotations['in-toto.io/predicate-type'] -match '^https://slsa\.dev/provenance/v(?:0\.2|1)$'
        }
    )
    if ($provenanceLayers.Count -ne 1) {
        throw "published attestation manifest must contain exactly one in-toto SLSA provenance layer; found $($provenanceLayers.Count)"
    }

    $imageJson = Invoke-NativeProcess docker @(
        'buildx',
        'imagetools',
        'inspect',
        '--format',
        '{{json .Image}}',
        $manifestReference
    )
    $image = ConvertFrom-RequiredJsonObject -Json $imageJson -Description 'published platform image configuration inspection'
    $config = Get-RequiredDictionaryValue $image config 'published platform image configuration inspection'
    if ($config -isnot [System.Collections.IDictionary]) {
        throw 'published platform image configuration must contain a config object'
    }
    $labels = ConvertTo-ImageLabelMap `
        -Labels (Get-RequiredDictionaryValue $config Labels 'published platform image configuration') `
        -Description 'published platform image configuration'
    Assert-LabelMapsEqual -Expected $snapshot.Labels -Actual $labels
}

Export-ModuleMember -Function 'Confirm-PublishedImageMetadata'
