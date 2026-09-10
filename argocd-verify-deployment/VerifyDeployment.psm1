#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'ActionRuntime.psm1') -Force

function Invoke-VerifyDeployment {
    $requiredVariables = @(
        'INPUT_SERVER'
        'INPUT_APPLICATION'
        'INPUT_AUTH_TOKEN'
        'INPUT_CLOUDFLARE_ACCESS_CLIENT_ID'
        'INPUT_CLOUDFLARE_ACCESS_CLIENT_SECRET'
        'INPUT_EXPECTED_COMMIT_SHA'
        'INPUT_TIMEOUT_SECONDS'
        'ARGOCD_CLI_PATH'
        'GITOPS_CHECKOUT_PATH'
    )
    foreach ($name in $requiredVariables) {
        $label = $name.ToLowerInvariant().Replace('input_', '').Replace('_', '-')
        Assert-SingleLine ([Environment]::GetEnvironmentVariable($name)) $label | Out-Null
    }

    if ($env:INPUT_EXPECTED_COMMIT_SHA -notmatch '^[0-9a-f]{40}$') {
        throw 'expected-commit-sha must be a full lowercase 40-character Git SHA'
    }
    if ($env:INPUT_TIMEOUT_SECONDS -notmatch '^[1-9][0-9]*$') {
        throw 'timeout-seconds must be a positive integer'
    }

    $arguments = @(
        '--server', $env:INPUT_SERVER
        '--grpc-web'
        '--header', "CF-Access-Client-Id: $env:INPUT_CLOUDFLARE_ACCESS_CLIENT_ID"
        '--header', "CF-Access-Client-Secret: $env:INPUT_CLOUDFLARE_ACCESS_CLIENT_SECRET"
        'app', 'wait', $env:INPUT_APPLICATION
        '--sync', '--health'
        '--timeout', $env:INPUT_TIMEOUT_SECONDS
        '--output', 'json'
    )
    $overlay = @{ ARGOCD_AUTH_TOKEN = $env:INPUT_AUTH_TOKEN; INPUT_AUTH_TOKEN = $null }
    $result = Invoke-NativeProcess $env:ARGOCD_CLI_PATH $arguments -Environment $overlay -RawOutput -AllowFailure

    $application = $null
    try {
        $application = $result.StandardOutput | ConvertFrom-Json
    } catch {
    }

    $sync = ''
    $health = ''
    $revision = ''
    if ($null -ne $application) {
        $sync = [string] $application.status.sync.status
        $health = [string] $application.status.health.status
        $revision = [string] $application.status.sync.revision
    }

    if ($health -in 'Degraded', 'Missing', 'Unknown') {
        throw "Application '$env:INPUT_APPLICATION' is unhealthy (sync=$sync, health=$health)"
    }
    if ($result.ExitCode) {
        foreach ($line in $result.StandardError.TrimEnd() -split "`r?`n") {
            if ($line) {
                [Console]::Error.WriteLine("argocd: $line")
            }
        }

        throw (
            "Application '$env:INPUT_APPLICATION' did not become Synced and Healthy " +
            "within $env:INPUT_TIMEOUT_SECONDS`s"
        )
    }
    if ($sync -ne 'Synced' -or $health -ne 'Healthy') {
        throw "Argo CD returned success without a Synced and Healthy Application (sync=$sync, health=$health)"
    }
    if ($revision -notmatch '^[0-9a-f]{40}$') {
        throw "Argo CD reported an unavailable synchronized revision: $revision"
    }

    foreach ($sha in $env:INPUT_EXPECTED_COMMIT_SHA, $revision) {
        $availabilityArguments = @(
            '-C'
            $env:GITOPS_CHECKOUT_PATH
            'cat-file'
            '-e'
            "$sha`^{commit}"
        )
        $available = Invoke-NativeProcess git $availabilityArguments -RawOutput -AllowFailure
        if ($available.ExitCode) {
            throw "GitOps revision is unavailable: $sha"
        }
    }

    if ($env:INPUT_EXPECTED_COMMIT_SHA -ne $revision) {
        $ancestryArguments = @(
            '-C'
            $env:GITOPS_CHECKOUT_PATH
            'merge-base'
            '--is-ancestor'
            $env:INPUT_EXPECTED_COMMIT_SHA
            $revision
        )
        $ancestry = Invoke-NativeProcess git $ancestryArguments -RawOutput -AllowFailure
        if ($ancestry.ExitCode -eq 1) {
            throw (
                "expected GitOps revision $env:INPUT_EXPECTED_COMMIT_SHA is not an ancestor " +
                "of synchronized revision $revision"
            )
        }
        if ($ancestry.ExitCode) {
            throw 'Git could not verify the synchronized revision ancestry'
        }
    }

    if ($env:INPUT_SMOKE_URL) {
        Assert-SingleLine $env:INPUT_SMOKE_URL 'smoke-url' | Out-Null
        $temporaryRoot = (Resolve-Path $env:RUNNER_TEMP).Path
        $smokeOutput = Join-Path $temporaryRoot "argocd-smoke.$([Guid]::NewGuid().ToString('N'))"

        $smokeArguments = @(
            '--silent', '--show-error', '--fail'
            '--output', $smokeOutput
            '--max-time', $env:INPUT_TIMEOUT_SECONDS
            '--header', "CF-Access-Client-Id: $env:INPUT_CLOUDFLARE_ACCESS_CLIENT_ID"
            '--header', "CF-Access-Client-Secret: $env:INPUT_CLOUDFLARE_ACCESS_CLIENT_SECRET"
            '--', $env:INPUT_SMOKE_URL
        )

        try {
            $smoke = Invoke-NativeProcess curl $smokeArguments -RawOutput -AllowFailure
            if ($smoke.ExitCode) {
                throw "authenticated HTTP smoke test failed: $env:INPUT_SMOKE_URL"
            }
        } finally {
            if (Test-Path $smokeOutput) {
                Remove-ContainedTemporaryResource $smokeOutput $temporaryRoot
            }
        }
    }

    Write-GitHubOutput 'synchronized-revision' $revision
    Write-Output "Verified Argo CD Application $env:INPUT_APPLICATION at synchronized revision $revision."
}

Export-ModuleMember -Function Invoke-VerifyDeployment
