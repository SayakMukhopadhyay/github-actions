#requires -Version 7.4

Import-Module (Join-Path $PSScriptRoot 'ContainerPromotion.psm1') -Force

Invoke-ContainerPromotion
