<#
.SYNOPSIS

.EXAMPLE
    .\Invoke-PolicyAudit-Locations.ps1
#>

[CmdletBinding()]
param()

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

# System settings and variables

$CustomerName = "Asphalt Enterprises"
$ToAddresses = @("bwinklesky@servit.net")

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

    & (Join-Path $PSScriptRoot "..\scripts\Invoke-PolicyAudit-Locations-Default.ps1") `
    -CustomerDir $CustomerDir `
    -SpFolder $SpFolder `
    -FromAddress $FromAddress `
    -ToAddresses $ToAddresses

}
catch {

    Write-Host "$($_.Exception.Message)"

    exit 1

}
