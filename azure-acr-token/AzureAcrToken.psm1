#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'ActionRuntime.psm1') -Force

function Invoke-AzureAcrTokenAction {
    $loginServer = Assert-SingleLine -Value $env:INPUT_LOGIN_SERVER -Name 'login-server'
    if ($loginServer -notmatch '^[A-Za-z0-9.-]+$') {
        throw 'login-server must be an Azure Container Registry host without a scheme, path, port, or whitespace'
    }

    $normalized = $loginServer.ToLowerInvariant()
    if ($normalized -notmatch '^([a-z0-9]{5,50})(-([a-z0-9]+))?\.azurecr\.io$') {
        throw 'login-server must match <registry>.azurecr.io or <registry>-<suffix>.azurecr.io'
    }

    $registryName = $Matches[1]
    $suffix = $Matches[3]
    if (($normalized -replace '\.azurecr\.io$').Length -gt 63) {
        throw 'login-server has an invalid DNS label length'
    }

    $arguments = @('acr', 'login', '--name', $registryName)
    if ($suffix) {
        $arguments += @('--suffix', $suffix)
    }

    $arguments += @('--expose-token', '--query', 'accessToken', '--output', 'tsv')
    $result = Invoke-NativeProcess -FilePath 'az' -ArgumentList $arguments -RawOutput -AllowFailure
    if ($result.ExitCode -ne 0) {
        throw 'Azure CLI failed to expose an Azure Container Registry access token'
    }

    $token = $result.StandardOutput.TrimEnd("`r", "`n")
    Assert-SingleLine -Value $token -Name 'Azure Container Registry access token' | Out-Null

    Add-GitHubMask -Value $token
    Write-GitHubOutput -Name 'username' -Value '00000000-0000-0000-0000-000000000000'
    Write-GitHubOutput -Name 'access-token' -Value $token
}

Export-ModuleMember -Function Invoke-AzureAcrTokenAction
