#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'ActionRuntime.psm1') -Force

function Invoke-PublishRelease {
    $token = Assert-SingleLine $env:INPUT_TOKEN token
    $factsPath = (Resolve-Path $env:FACTS_FILE).Path
    $runnerTemp = (Resolve-Path $env:RUNNER_TEMP).Path
    $runnerPrefix = $runnerTemp.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $factsPath.StartsWith($runnerPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'facts-file must be contained by RUNNER_TEMP'
    }

    $facts = Get-Content -Raw $factsPath | ConvertFrom-Json
    $requiredFacts = @(
        'schemaVersion'
        'repository'
        'serverUrl'
        'tagName'
        'targetObject'
        'targetCommit'
        'previousTag'
        'previousObject'
        'commits'
        'omittedCommitCount'
    )
    $factNames = @($facts.PSObject.Properties | ForEach-Object { $_.Name })
    if (@($requiredFacts | Where-Object { $_ -notin $factNames }).Count) {
        throw 'release facts are malformed'
    }
    $factsAreInvalid = (
        $facts.schemaVersion -ne 1 -or
        $facts.repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or
        $facts.tagName.Contains("`n") -or
        $facts.targetObject -notmatch '^[0-9a-fA-F]{40,64}$'
    )

    if ($factsAreInvalid) {
        throw 'release facts are malformed'
    }

    $mode = if ($env:PUBLISH_MODE) {
        $env:PUBLISH_MODE
    } else {
        'publish'
    }

    if ($mode -notin 'check', 'publish') {
        throw 'PUBLISH_MODE must be check or publish'
    }
    $encodedTag = [uri]::EscapeDataString($facts.tagName)
    $overlay = @{
        GH_TOKEN    = $token
        GH_HOST     = ([uri] $facts.serverUrl).Authority
        INPUT_TOKEN = $null
    }

    function Invoke-Gh([string[]] $Arguments) {
        Invoke-NativeProcess gh $Arguments -Environment $overlay -RawOutput -AllowFailure
    }

    function ConvertFrom-ReleaseResponse($Result) {
        if ($Result.ExitCode) {
            return $null
        }

        $release = $Result.StandardOutput | ConvertFrom-Json
        $releaseIsInvalid = (
            $release.id -le 0 -or
            $release.html_url -notmatch '^https://' -or
            $release.upload_url -notmatch '^https://'
        )

        if ($releaseIsInvalid) {
            throw 'GitHub returned malformed release details'
        }

        $release
    }

    function Write-ReleaseOutputs($Release) {
        Write-GitHubOutput 'release-id' ([string] $Release.id)
        Write-GitHubOutput 'html-url' $Release.html_url
        Write-GitHubOutput 'upload-url' $Release.upload_url
    }

    $tagEndpoint = "repos/$($facts.repository)/git/ref/tags/$encodedTag"
    $tagResponse = Invoke-Gh @('api', '--method', 'GET', $tagEndpoint)
    if ($tagResponse.ExitCode) {
        throw "could not reverify remote tag before release creation: $($facts.tagName)"
    }

    $remoteTag = $tagResponse.StandardOutput | ConvertFrom-Json
    if ($remoteTag.ref -ne "refs/tags/$($facts.tagName)" -or $remoteTag.object.sha -ne $facts.targetObject) {
        throw "remote tag moved during release creation: $($facts.tagName)"
    }
    if ($facts.previousTag) {
        $previousEncoded = [uri]::EscapeDataString($facts.previousTag)
        $previousEndpoint = "repos/$($facts.repository)/git/ref/tags/$previousEncoded"
        $previous = Invoke-Gh @('api', '--method', 'GET', $previousEndpoint)

        if ($previous.ExitCode -or ($previous.StandardOutput | ConvertFrom-Json).object.sha -ne $facts.previousObject) {
            throw "previous remote tag moved during release creation: $($facts.previousTag)"
        }
    }

    $releaseEndpoint = "repos/$($facts.repository)/releases/tags/$encodedTag"
    $existingResult = Invoke-Gh @('api', '--method', 'GET', $releaseEndpoint)
    $existing = ConvertFrom-ReleaseResponse $existingResult
    if ($existing) {
        Write-ReleaseOutputs $existing
        Write-GitHubOutput 'release-exists' 'true'
        return
    }

    if ($existingResult.StandardError -notmatch '(^|[^0-9])404([^0-9]|$)') {
        throw 'could not check for an existing GitHub Release'
    }
    if ($mode -eq 'check') {
        Write-GitHubOutput 'release-exists' 'false'
        return
    }

    $bodyPath = (Resolve-Path $env:BODY_FILE).Path
    if ([IO.Path]::GetDirectoryName($bodyPath) -ne [IO.Path]::GetDirectoryName($factsPath)) {
        throw 'release handoff files must share one session directory'
    }
    $body = [IO.File]::ReadAllText($bodyPath)
    if (-not $body.Length -or [Text.Encoding]::UTF8.GetByteCount($body) -gt 120000) {
        throw 'release body is empty or exceeds the maximum size'
    }

    $requestPath = Join-Path ([IO.Path]::GetDirectoryName($factsPath)) 'create-request.json'
    $request = @{
        tag_name               = $facts.tagName
        name                   = Assert-SingleLine $env:INPUT_RELEASE_NAME 'release-name'
        body                   = $body
        draft                  = $false
        prerelease             = $false
        generate_release_notes = $false
    }

    $request | ConvertTo-Json | Set-Content $requestPath -Encoding utf8NoBOM

    $createArguments = @(
        'api'
        '--method'
        'POST'
        "repos/$($facts.repository)/releases"
        '--input'
        $requestPath
    )
    $created = ConvertFrom-ReleaseResponse (Invoke-Gh $createArguments)
    if ($created) {
        Write-ReleaseOutputs $created
        return
    }

    $concurrent = ConvertFrom-ReleaseResponse (Invoke-Gh @('api', '--method', 'GET', $releaseEndpoint))
    if ($concurrent) {
        Write-ReleaseOutputs $concurrent
        return
    }

    throw 'GitHub Release creation failed'
}

Export-ModuleMember -Function 'Invoke-PublishRelease'
