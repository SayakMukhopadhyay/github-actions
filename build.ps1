#requires -Version 7.4

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('Bootstrap', 'Format', 'FormatCheck', 'Lint', 'Test', 'Validate')]
    [string] $Task = 'Validate'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$tools = Join-Path $root '.tools'
$modules = Join-Path $tools 'modules'
$bin = Join-Path $tools 'bin'
$formatSettings = Join-Path $root 'PowerShellFormatting.psd1'
$structuralFormatSettings = Join-Path $root 'PowerShellStructuralFormatting.psd1'
$env:PSModulePath = "$modules$([IO.Path]::PathSeparator)$env:PSModulePath"
$env:PATH = "$bin$([IO.Path]::PathSeparator)$env:PATH"

function Invoke-Native {
    param([string] $File, [string[]] $Arguments)
    & $File @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$File failed with exit code $LASTEXITCODE"
    }
}

function Save-Download {
    param([string] $Uri, [string] $Destination)
    Invoke-WebRequest -Uri $Uri -OutFile $Destination -UseBasicParsing
}

function Assert-Sha256 {
    param([string] $Path, [string] $Expected)
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Expected.Trim().ToLowerInvariant()) {
        Remove-Item -LiteralPath $Path -Force
        throw "SHA-256 verification failed for $([IO.Path]::GetFileName($Path))"
    }
}

function Bootstrap {
    if ($PSVersionTable.PSVersion -lt [version] '7.4') {
        throw 'PowerShell 7.4 or newer is required'
    }
    if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne [Runtime.InteropServices.Architecture]::X64) {
        throw 'Bootstrap currently supports the x64 GitHub-hosted runner architecture'
    }

    $platform = if ($IsWindows) {
        'windows'
    } elseif ($IsLinux) {
        'linux'
    } else {
        throw 'Bootstrap currently supports Windows and Linux'
    }
    $executableSuffix = if ($IsWindows) {
        '.exe'
    } else {
        ''
    }

    New-Item -ItemType Directory -Force $modules, $bin | Out-Null
    Save-Module Pester -RequiredVersion 6.1.0 -Path $modules -Repository PSGallery -Force
    Save-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Path $modules -Repository PSGallery -Force

    $helmVersion = '4.2.4'
    $helmArchive = "helm-v$helmVersion-$platform-amd64$(if ($IsWindows) { '.zip' } else { '.tar.gz' })"
    $helmDownload = Join-Path $tools $helmArchive
    $helmChecksum = Join-Path $tools "$helmArchive.sha256sum"
    Save-Download "https://get.helm.sh/$helmArchive" $helmDownload
    Save-Download "https://get.helm.sh/$helmArchive.sha256sum" $helmChecksum
    Assert-Sha256 $helmDownload ((Get-Content -Raw $helmChecksum) -split '\s+')[0]

    $helmExtract = Join-Path $tools 'helm-extract'
    if (Test-Path $helmExtract) {
        Remove-Item -LiteralPath $helmExtract -Recurse -Force
    }
    New-Item -ItemType Directory $helmExtract | Out-Null
    if ($IsWindows) {
        Expand-Archive $helmDownload $helmExtract
    } else {
        Invoke-Native tar @('-xzf', $helmDownload, '-C', $helmExtract)
    }
    $helmSource = Join-Path $helmExtract "$platform-amd64/helm$executableSuffix"
    $helmDestination = Join-Path $bin "helm$executableSuffix"
    Copy-Item $helmSource $helmDestination -Force

    $yqVersion = '4.53.3'
    $yqAsset = "yq_$($platform)_amd64$executableSuffix"
    $yqDownload = Join-Path $tools $yqAsset
    $yqChecksums = Join-Path $tools 'yq-checksums'
    Save-Download "https://github.com/mikefarah/yq/releases/download/v$yqVersion/$yqAsset" $yqDownload
    Save-Download "https://github.com/mikefarah/yq/releases/download/v$yqVersion/checksums" $yqChecksums
    $yqHash = (Get-FileHash $yqDownload -Algorithm SHA256).Hash.ToLowerInvariant()
    $yqRecord = Get-Content $yqChecksums | Where-Object { $_ -like "$yqAsset *" }
    if (-not $yqRecord -or -not (($yqRecord -split '\s+') -contains $yqHash)) {
        Remove-Item -LiteralPath $yqDownload -Force
        throw 'SHA-256 verification failed for yq'
    }
    Copy-Item $yqDownload (Join-Path $bin "yq$executableSuffix") -Force

    $actionlintVersion = '1.7.12'
    $actionlintExtension = if ($IsWindows) {
        'amd64.zip'
    } else {
        'amd64.tar.gz'
    }
    $actionlintArchive = "actionlint_$actionlintVersion`_$platform`_$actionlintExtension"
    $actionlintDownload = Join-Path $tools $actionlintArchive
    Invoke-Native gh @(
        'release'
        'download'
        "v$actionlintVersion"
        '--repo'
        'rhysd/actionlint'
        '--pattern'
        $actionlintArchive
        '--dir'
        $tools
        '--clobber'
    )
    Invoke-Native gh @('attestation', 'verify', $actionlintDownload, '--repo', 'rhysd/actionlint')

    $actionlintExtract = Join-Path $tools 'actionlint-extract'
    if (Test-Path $actionlintExtract) {
        Remove-Item -LiteralPath $actionlintExtract -Recurse -Force
    }
    New-Item -ItemType Directory $actionlintExtract | Out-Null
    if ($IsWindows) {
        Expand-Archive $actionlintDownload $actionlintExtract
    } else {
        Invoke-Native tar @('-xzf', $actionlintDownload, '-C', $actionlintExtract, 'actionlint')
    }
    $actionlintSource = Join-Path $actionlintExtract "actionlint$executableSuffix"
    $actionlintDestination = Join-Path $bin "actionlint$executableSuffix"
    Copy-Item $actionlintSource $actionlintDestination -Force

    if ($env:GITHUB_PATH) {
        [IO.File]::AppendAllText($env:GITHUB_PATH, "$bin$([Environment]::NewLine)")
    }
    Invoke-Native helm @('version', '--short')
    Invoke-Native yq @('--version')
    Invoke-Native actionlint @('-version')
    Write-Output 'Pinned PowerShell modules and verified native tools are installed.'
}

function Get-PowerShellFiles {
    Get-ChildItem $root -Recurse -Include *.ps1, *.psm1, *.psd1 -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[\\/](node_modules|\.tools)[\\/]' }
}

function Format-PowerShellSource {
    param([Parameter(Mandatory)] [string] $Source)

    # PSScriptAnalyzer 1.25.0 can fail when opening and closing one-line
    # blocks are expanded in the same formatter pass. Expanding opening
    # braces first makes the complete formatting profile deterministic.
    $structuralOptions = @{
        ScriptDefinition = $Source
        Settings         = $structuralFormatSettings
    }
    $structurallyFormatted = Invoke-Formatter @structuralOptions

    $formatOptions = @{
        ScriptDefinition = $structurallyFormatted
        Settings         = $formatSettings
    }
    Invoke-Formatter @formatOptions
}

function Format {
    Import-Module PSScriptAnalyzer -RequiredVersion 1.25.0
    foreach ($file in Get-PowerShellFiles) {
        $formatted = Format-PowerShellSource -Source (Get-Content -Raw $file.FullName)
        [IO.File]::WriteAllText($file.FullName, $formatted, [Text.UTF8Encoding]::new($false))
    }
}

function FormatCheck {
    Import-Module PSScriptAnalyzer -RequiredVersion 1.25.0
    foreach ($file in Get-PowerShellFiles) {
        $source = Get-Content -Raw $file.FullName
        if ($source -ne (Format-PowerShellSource -Source $source)) {
            throw "PowerShell formatting drift: $($file.FullName)"
        }
    }
}

function Lint {
    Import-Module PSScriptAnalyzer -RequiredVersion 1.25.0
    $issues = @(Get-PowerShellFiles | ForEach-Object { Invoke-ScriptAnalyzer -Path $_.FullName -Severity Error })
    if ($issues.Count) {
        $issues | Format-Table | Out-String | Write-Error
    }
}

function Test {
    Import-Module Pester -RequiredVersion 6.1.0
    $result = Invoke-Pester -Path (Join-Path $root 'tests') -PassThru
    if ($result.FailedCount) {
        throw "$($result.FailedCount) Pester tests failed"
    }
}

function Assert-NoBash {
    $tracked = @(Invoke-Native git @('ls-files') | Where-Object { Test-Path (Join-Path $root $_) })
    $forbidden = @($tracked | Where-Object { $_ -match '\.(sh|bash|bats)$' })
    if ($forbidden.Count) {
        throw "Tracked Bash/Bats files are forbidden: $($forbidden -join ', ')"
    }

    $searchArguments = @(
        '-C'
        $root
        'grep'
        '-n'
        '--untracked'
        '--exclude-standard'
        '--extended-regexp'
        '(shell:[[:space:]]*bash|#!/usr/bin/env bash|(^|[^[:alnum:]_])bash[[:space:]]+["''][^[:space:]])'
        '--'
        '.'
        ':(exclude)package-lock.json'
        ':(exclude)build.ps1'
        ':(exclude)tests/PowerShellPolicy.Tests.ps1'
    )
    $references = @(& git @searchArguments)
    $searchExitCode = $LASTEXITCODE
    if ($searchExitCode -eq 0) {
        throw "Bash invocation/reference policy failed:`n$($references -join "`n")"
    }
    if ($searchExitCode -ne 1) {
        throw 'git grep policy scan failed'
    }
}

function Validate {
    FormatCheck
    Lint
    Test
    Assert-NoBash
    Invoke-Native git @('diff', '--check')
    if (Get-Command actionlint -ErrorAction SilentlyContinue) {
        Invoke-Native actionlint @()
    }
}

& $Task
