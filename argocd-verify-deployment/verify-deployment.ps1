#requires -Version 7.4

Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'ActionRuntime.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'VerifyDeployment.psm1') -Force

try {
    Invoke-VerifyDeployment
} catch {
    Write-GitHubAnnotation -Message "argocd-verify-deployment: $($_.Exception.Message)"
    exit 1
}
