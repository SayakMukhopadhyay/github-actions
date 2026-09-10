@{
    IncludeRules = @(
        'PSPlaceOpenBrace'
    )

    Rules        = @{
        PSPlaceOpenBrace = @{
            Enable             = $true
            OnSameLine         = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $false
        }
    }
}
