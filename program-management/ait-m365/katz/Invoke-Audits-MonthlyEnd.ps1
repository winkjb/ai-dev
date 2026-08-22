<#
.SYNOPSIS

.EXAMPLE
    .\Invoke-Audits-MonthlyEnd.ps1
#>

[CmdletBinding()]
param()

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

# System settings and variables

$CustomerName = "Katz"
$ToAddresses = @("automation@alerts.servit.net")

# Import functions

. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-VA-Common.ps1")

# ---------------------------------------------------------------------------
# Run tasks
# ---------------------------------------------------------------------------

# Script settings and variables

$CustomerSettings = Map-Customer $CustomerName
$CustomerDir = $CustomerSettings.Directory
$SpFolder = $CustomerSettings.SharepointFolder
$FromAddress = $CustomerSettings.FromAddress

try {

    & (Join-Path $PSScriptRoot "..\scripts\Invoke-Audits-Default.ps1") `
    -CustomerDir $CustomerDir `
    -Cadence "Monthly-End" `
    -SpFolder $SpFolder `
    -FromAddress $FromAddress `
    -ToAddresses $ToAddresses

}
catch {

    Write-Host "$($_.Exception.Message)"

    exit 1

}
