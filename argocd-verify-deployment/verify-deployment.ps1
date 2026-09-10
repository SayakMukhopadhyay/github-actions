#requires -Version 7.4

Import-Module (Join-Path $PSScriptRoot 'VerifyDeployment.psm1') -Force

try {
    Invoke-VerifyDeployment
} catch {
    [Console]::Error.WriteLine("argocd-verify-deployment: $($_.Exception.Message)")
    exit 1
}
