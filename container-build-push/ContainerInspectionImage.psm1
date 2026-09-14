#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'ActionRuntime.psm1')
Import-Module (Join-Path $PSScriptRoot 'ContainerMetadata.psm1')

function Read-LocalImageMetadata {
    $reference = Assert-SingleLine -Value $env:INSPECTION_REFERENCE -Name 'inspection-reference'
    $json = Invoke-NativeProcess docker @('image', 'inspect', '--format', '{{json .}}', $reference)
    $image = ConvertFrom-RequiredJsonObject -Json $json -Description 'local Docker image inspection'
    $config = Get-RequiredDictionaryValue $image Config 'local Docker image inspection'
    if ($config -isnot [System.Collections.IDictionary]) {
        throw 'local Docker image inspection Config must be a JSON object'
    }
    $labels = ConvertTo-ImageLabelMap `
        -Labels (Get-RequiredDictionaryValue $config Labels 'local Docker image inspection Config') `
        -Description 'local Docker image inspection'
    $operatingSystem = Get-RequiredDictionaryValue $image Os 'local Docker image inspection'
    $architecture = Get-RequiredDictionaryValue $image Architecture 'local Docker image inspection'
    $variant = if ($image.Contains('Variant') -and $null -ne $image.Variant) {
        $image.Variant
    } else {
        ''
    }
    foreach ($coordinate in @($operatingSystem, $architecture, $variant)) {
        if ($coordinate -isnot [string]) {
            throw 'local Docker image platform coordinates must be strings'
        }
    }

    Write-GitHubOutput annotations (ConvertTo-ImageAnnotations -Labels $labels)
    Write-GitHubOutput label-snapshot (
        ConvertTo-LabelSnapshot `
            -Labels $labels `
            -OperatingSystem $operatingSystem `
            -Architecture $architecture `
            -Variant $variant
    )
}

function Remove-LocalInspectionImage {
    if ([string]::IsNullOrWhiteSpace($env:INSPECTION_REFERENCE)) {
        return
    }
    $reference = Assert-SingleLine -Value $env:INSPECTION_REFERENCE -Name 'inspection-reference'
    $result = Invoke-NativeProcess docker @('image', 'rm', '--force', $reference) -RawOutput -AllowFailure
    if ($result.ExitCode -eq 0) {
        return
    }
    $diagnostic = "$($result.StandardOutput)`n$($result.StandardError)"
    if ($diagnostic -notmatch '(?i)(no such image|image not known)') {
        throw "failed to remove local inspection image: $($result.StandardError.Trim())"
    }
}

Export-ModuleMember -Function @(
    'Read-LocalImageMetadata'
    'Remove-LocalInspectionImage'
)
