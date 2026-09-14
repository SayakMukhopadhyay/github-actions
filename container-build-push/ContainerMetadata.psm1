#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:PackageAnnotationLabels = @(
    'org.opencontainers.image.created'
    'org.opencontainers.image.authors'
    'org.opencontainers.image.url'
    'org.opencontainers.image.documentation'
    'org.opencontainers.image.source'
    'org.opencontainers.image.version'
    'org.opencontainers.image.revision'
    'org.opencontainers.image.vendor'
    'org.opencontainers.image.licenses'
    'org.opencontainers.image.title'
    'org.opencontainers.image.description'
)
$script:ManifestAnnotationLabels = @(
    'org.opencontainers.image.base.name'
    'org.opencontainers.image.base.digest'
)

function ConvertFrom-JsonElement {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Text.Json.JsonElement] $Element)

    switch ($Element.ValueKind) {
        ([Text.Json.JsonValueKind]::Object) {
            $result = [ordered]@{}
            foreach ($property in $Element.EnumerateObject()) {
                if ($result.Contains($property.Name)) {
                    throw "JSON object contains duplicate property $($property.Name)"
                }
                $result[$property.Name] = ConvertFrom-JsonElement -Element $property.Value
            }
            return $result
        }
        ([Text.Json.JsonValueKind]::Array) {
            $items = [Collections.Generic.List[object]]::new()
            foreach ($item in $Element.EnumerateArray()) {
                $items.Add((ConvertFrom-JsonElement -Element $item))
            }
            return , $items.ToArray()
        }
        ([Text.Json.JsonValueKind]::String) {
            return $Element.GetString()
        }
        ([Text.Json.JsonValueKind]::Number) {
            [long] $integer = 0
            if ($Element.TryGetInt64([ref] $integer)) {
                return $integer
            }
            [decimal] $number = 0
            if ($Element.TryGetDecimal([ref] $number)) {
                return $number
            }
            return $Element.GetDouble()
        }
        ([Text.Json.JsonValueKind]::True) {
            return $true
        }
        ([Text.Json.JsonValueKind]::False) {
            return $false
        }
        ([Text.Json.JsonValueKind]::Null) {
            return $null
        }
        default {
            throw "unsupported JSON value kind $($Element.ValueKind)"
        }
    }
}

function ConvertFrom-RequiredJsonObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Json,
        [Parameter(Mandatory)][string] $Description
    )

    if ([string]::IsNullOrWhiteSpace($Json)) {
        throw "$Description returned empty JSON"
    }
    $document = $null
    try {
        $options = [Text.Json.JsonDocumentOptions]@{ MaxDepth = 100 }
        $document = [Text.Json.JsonDocument]::Parse($Json, $options)
        $value = ConvertFrom-JsonElement -Element $document.RootElement
    } catch {
        throw "$Description returned malformed JSON: $($_.Exception.Message)"
    } finally {
        if ($null -ne $document) {
            $document.Dispose()
        }
    }
    if ($value -isnot [System.Collections.IDictionary]) {
        throw "$Description must be one JSON object"
    }
    $value
}

function Get-RequiredDictionaryValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Dictionary,
        [Parameter(Mandatory)][string] $Key,
        [Parameter(Mandatory)][string] $Description
    )

    if (-not $Dictionary.Contains($Key)) {
        throw "$Description is missing $Key"
    }
    $Dictionary[$Key]
}

function ConvertTo-ImageLabelMap {
    [CmdletBinding()]
    param(
        [AllowNull()] $Labels,
        [Parameter(Mandatory)][string] $Description
    )

    $result = [ordered]@{}
    if ($null -eq $Labels) {
        return $result
    }
    if ($Labels -isnot [System.Collections.IDictionary]) {
        throw "$Description labels must be a JSON object or null"
    }
    foreach ($key in @($Labels.Keys | Sort-Object -CaseSensitive)) {
        if ($key -isnot [string] -or $Labels[$key] -isnot [string]) {
            throw "$Description label names and values must be strings"
        }
        $result[$key] = $Labels[$key]
    }
    $result
}

function Assert-SupportedAnnotationValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Value
    )

    if ($Value -ne $Value.Trim()) {
        throw "$Name cannot be converted to an annotation because leading or trailing whitespace is unsupported"
    }
    foreach ($character in $Value.ToCharArray()) {
        $category = [Globalization.CharUnicodeInfo]::GetUnicodeCategory($character)
        if (
            [char]::IsControl($character) -or
            $category -in @(
                [Globalization.UnicodeCategory]::Format,
                [Globalization.UnicodeCategory]::LineSeparator,
                [Globalization.UnicodeCategory]::ParagraphSeparator,
                [Globalization.UnicodeCategory]::Surrogate
            )
        ) {
            throw "$Name cannot be converted to an annotation because control or separator characters are unsupported"
        }
    }
}

function ConvertTo-ImageAnnotations {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Labels)

    $annotations = [Collections.Generic.List[string]]::new()
    foreach ($name in $script:PackageAnnotationLabels) {
        if ($Labels.Contains($name)) {
            $value = [string] $Labels[$name]
            Assert-SupportedAnnotationValue -Name $name -Value $value
            $annotations.Add("index,manifest:$name=$value")
        }
    }
    foreach ($name in $script:ManifestAnnotationLabels) {
        if ($Labels.Contains($name)) {
            $value = [string] $Labels[$name]
            Assert-SupportedAnnotationValue -Name $name -Value $value
            $annotations.Add("manifest:$name=$value")
        }
    }
    $annotations -join "`n"
}

function ConvertTo-LabelSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Labels,
        [Parameter(Mandatory)][string] $OperatingSystem,
        [Parameter(Mandatory)][string] $Architecture,
        [AllowEmptyString()][string] $Variant = ''
    )

    $snapshot = [ordered]@{
        os           = $OperatingSystem
        architecture = $Architecture
        variant      = $Variant
        labels       = $Labels
    }
    $json = ConvertTo-Json -InputObject $snapshot -Compress -Depth 100
    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
}

function ConvertFrom-LabelSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Snapshot)

    try {
        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Snapshot))
    } catch {
        throw "image label snapshot is malformed: $($_.Exception.Message)"
    }
    $record = ConvertFrom-RequiredJsonObject -Json $json -Description 'image label snapshot'
    $labels = ConvertTo-ImageLabelMap `
        -Labels (Get-RequiredDictionaryValue $record labels 'image label snapshot') `
        -Description 'image label snapshot'
    foreach ($name in @('os', 'architecture', 'variant')) {
        if (-not $record.Contains($name) -or $record[$name] -isnot [string]) {
            throw "image label snapshot is missing string property $name"
        }
    }
    [pscustomobject]@{
        OperatingSystem = $record.os
        Architecture    = $record.architecture
        Variant         = $record.variant
        Labels          = $labels
    }
}

function Assert-LabelMapsEqual {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Expected,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Actual
    )

    if ($Expected.Count -ne $Actual.Count) {
        throw 'published platform image labels do not match the inspected image label snapshot'
    }
    foreach ($name in $Expected.Keys) {
        if (-not $Actual.Contains($name) -or $Actual[$name] -cne $Expected[$name]) {
            throw 'published platform image labels do not match the inspected image label snapshot'
        }
    }
}

function Assert-ExpectedAnnotations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $ExpectedLabels,
        [AllowNull()] $ActualAnnotations,
        [Parameter(Mandatory)][ValidateSet('Index', 'Manifest')][string] $Level
    )

    if ($ActualAnnotations -isnot [System.Collections.IDictionary]) {
        throw "published $($Level.ToLowerInvariant()) annotations are missing or malformed"
    }
    foreach ($name in $script:PackageAnnotationLabels) {
        if ($ExpectedLabels.Contains($name)) {
            if (-not $ActualAnnotations.Contains($name) -or $ActualAnnotations[$name] -cne $ExpectedLabels[$name]) {
                throw "published $($Level.ToLowerInvariant()) annotation $name does not match the inspected label"
            }
        }
    }
    foreach ($name in $script:ManifestAnnotationLabels) {
        if ($Level -eq 'Index' -and $ActualAnnotations.Contains($name)) {
            throw "published index annotation $name must remain manifest-only"
        }
        if ($Level -eq 'Manifest' -and $ExpectedLabels.Contains($name)) {
            if (-not $ActualAnnotations.Contains($name) -or $ActualAnnotations[$name] -cne $ExpectedLabels[$name]) {
                throw "published manifest annotation $name does not match the inspected label"
            }
        }
    }
}

Export-ModuleMember -Function @(
    'ConvertFrom-RequiredJsonObject'
    'Get-RequiredDictionaryValue'
    'ConvertTo-ImageLabelMap'
    'ConvertTo-ImageAnnotations'
    'ConvertTo-LabelSnapshot'
    'ConvertFrom-LabelSnapshot'
    'Assert-LabelMapsEqual'
    'Assert-ExpectedAnnotations'
)
