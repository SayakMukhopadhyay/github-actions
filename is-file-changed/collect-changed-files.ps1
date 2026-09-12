#requires -Version 7.4

Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'ActionRuntime.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ChangedFiles.psm1') -Force

try {
    $mode = if ($args.Count) {
        $args[0]
    } else {
        'collect'
    }
    Invoke-ChangedFilesAction -Mode $mode
} catch {
    Write-GitHubAnnotation -Message $_.Exception.Message
    exit 1
}
