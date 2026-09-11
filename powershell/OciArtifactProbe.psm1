#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'ActionRuntime.psm1') -Force

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
    if ($diagnostic -match '(?i)(?:^|[^a-z_])(?:manifest|name)[ _]unknown(?:[^a-z_]|$)') {
        return [pscustomobject]@{
            Exists         = $false
            StandardOutput = ''
        }
    }

    $safeError = $result.StandardError.TrimEnd()
    throw "OCI artifact probe failed with exit code $($result.ExitCode): $FilePath$(if ($safeError) { "`n$safeError" })"
}

Export-ModuleMember -Function Invoke-OciArtifactProbe
