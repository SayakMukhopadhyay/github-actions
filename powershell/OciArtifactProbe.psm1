#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'ActionRuntime.psm1')

function Invoke-OciArtifactProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [Parameter(Mandatory)][string[]] $ArgumentList
    )

    $result = Invoke-NativeProcess $FilePath $ArgumentList -AllowFailure -RawOutput
    if ($result.ExitCode -eq 0) {
        return [pscustomobject]@{
            Exists         = $true
            StandardOutput = $result.StandardOutput
        }
    }

    $diagnostic = "$($result.StandardError)`n$($result.StandardOutput)"
    $isExactDockerReferenceAbsent = $false
    $isDockerImageInspection = (
        $FilePath -eq 'docker' -and
        $ArgumentList.Count -eq 6 -and
        $ArgumentList[0] -eq 'buildx' -and
        $ArgumentList[1] -eq 'imagetools' -and
        $ArgumentList[2] -eq 'inspect' -and
        $ArgumentList[3] -eq '--format' -and
        $ArgumentList[4] -eq '{{json .Manifest}}'
    )
    if ($isDockerImageInspection) {
        $referencePattern = [regex]::Escape($ArgumentList[-1])
        $isExactDockerReferenceAbsent = (
            $diagnostic -match "(?im)^ERROR:\s+${referencePattern}:\s+not found\s*$"
        )
    }
    if (
        $diagnostic -match '(?i)(?:^|[^a-z_])(?:manifest|name)[ _]unknown(?:[^a-z_]|$)' -or
        $isExactDockerReferenceAbsent
    ) {
        return [pscustomobject]@{
            Exists         = $false
            StandardOutput = ''
        }
    }

    $safeError = $result.StandardError.TrimEnd()
    throw "OCI artifact probe failed with exit code $($result.ExitCode): $FilePath$(if ($safeError) { "`n$safeError" })"
}

Export-ModuleMember -Function Invoke-OciArtifactProbe
