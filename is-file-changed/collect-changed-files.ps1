#requires -Version 7.4

Import-Module (Join-Path $PSScriptRoot 'ChangedFiles.psm1') -Force

try {
    Invoke-ChangedFilesAction -Mode $(if ($args.Count) {
            $args[0]
        } else {
            'collect'
        })
} catch {
    Write-Output "::error::$($_.Exception.Message)"
    exit 1
}
