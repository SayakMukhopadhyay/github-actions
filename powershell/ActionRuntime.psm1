#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-SingleLine {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Value, [Parameter(Mandatory)][string] $Name)

    $isInvalid = (
        [string]::IsNullOrWhiteSpace($Value) -or
        $Value.Contains("`n") -or
        $Value.Contains("`r") -or
        $Value.Contains([char] 0)
    )

    if ($isInvalid) {
        throw "$Name must be a non-empty single-line value"
    }

    $Value
}

function Invoke-NativeProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [string[]] $ArgumentList = @(),
        [AllowNull()][string] $StandardInput,
        [hashtable] $Environment = @{},
        [switch] $LineOutput,
        [switch] $RawOutput,
        [switch] $AllowFailure
    )

    $start = [System.Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $FilePath

    $location = Get-Location
    if ($location.Provider.Name -ne 'FileSystem') {
        throw 'Native processes require a filesystem working directory'
    }

    $start.WorkingDirectory = $location.ProviderPath
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.RedirectStandardInput = $PSBoundParameters.ContainsKey('StandardInput')
    foreach ($argument in $ArgumentList) {
        [void] $start.ArgumentList.Add($argument)
    }
    foreach ($entry in $Environment.GetEnumerator()) {
        if ($null -eq $entry.Value) {
            [void] $start.Environment.Remove([string] $entry.Key)
        } else {
            $start.Environment[[string] $entry.Key] = [string] $entry.Value
        }
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $start
    if (-not $process.Start()) {
        throw "Failed to start native process: $FilePath"
    }
    if ($PSBoundParameters.ContainsKey('StandardInput')) {
        $process.StandardInput.Write($StandardInput)
        $process.StandardInput.Close()
    }

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $result = [pscustomobject]@{
        ExitCode       = $process.ExitCode
        StandardOutput = $stdout
        StandardError  = $stderr
    }

    if (-not $AllowFailure -and $result.ExitCode -ne 0) {
        $safeError = $stderr.TrimEnd()
        throw "Native process failed with exit code $($result.ExitCode): $FilePath$(if ($safeError) { "`n$safeError" })"
    }

    if ($RawOutput) {
        return $result
    }

    $text = $stdout.TrimEnd("`r", "`n")
    if ($LineOutput) {
        if (-not $text) {
            return
        }
        return $text -split "`r?`n"
    }

    $text
}

function Write-GitHubOutput {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Name, [Parameter(Mandatory)][AllowEmptyString()][string] $Value)

    if (-not $env:GITHUB_OUTPUT) {
        throw 'GITHUB_OUTPUT is required'
    }

    Assert-SingleLine -Value $Name -Name 'output name' | Out-Null
    if ($Value.Contains("`n") -or $Value.Contains("`r")) {
        return Write-GitHubMultilineOutput -Name $Name -Value $Value
    }

    $record = "$Name=$Value$([Environment]::NewLine)"
    [System.IO.File]::AppendAllText(
        $env:GITHUB_OUTPUT,
        $record,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Write-GitHubMultilineOutput {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Name, [Parameter(Mandatory)][AllowEmptyString()][string] $Value)

    if (-not $env:GITHUB_OUTPUT) {
        throw 'GITHUB_OUTPUT is required'
    }

    $delimiter = "gho_$([Guid]::NewGuid().ToString('N'))"
    $newline = [Environment]::NewLine
    $record = "$Name<<${delimiter}${newline}${Value}${newline}${delimiter}${newline}"
    [System.IO.File]::AppendAllText(
        $env:GITHUB_OUTPUT,
        $record,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Add-GitHubMask {
    param([Parameter(Mandatory)][string] $Value)

    Write-Output "::add-mask::$Value"
}

function Write-GitHubAnnotation {
    param(
        [ValidateSet('error', 'warning', 'notice')]
        [string] $Level = 'error',

        [Parameter(Mandatory)]
        [string] $Message
    )

    Write-Output "::$Level::$($Message.Replace("`r", '%0D').Replace("`n", '%0A'))"
}

function Remove-ContainedTemporaryResource {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $TemporaryRoot)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $separator = [System.IO.Path]::DirectorySeparatorChar
    $root = [System.IO.Path]::GetFullPath($TemporaryRoot).TrimEnd($separator) + $separator
    $target = [System.IO.Path]::GetFullPath($Path)
    if (-not $target.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'temporary resource escapes the owned temporary root'
    }
    Remove-Item -LiteralPath $target -Recurse -Force
}

Export-ModuleMember -Function @(
    'Assert-SingleLine'
    'Invoke-NativeProcess'
    'Write-GitHubOutput'
    'Write-GitHubMultilineOutput'
    'Add-GitHubMask'
    'Write-GitHubAnnotation'
    'Remove-ContainedTemporaryResource'
)
