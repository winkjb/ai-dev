<#
.SYNOPSIS
    Unattended entry point for Katz's Entra user sign-in log export - runs the collector and
    emails (or, if too large, notifies about) the raw log. Meant to be called from a scheduled
    task.

.EXAMPLE
    .\Invoke-LogAudit-UserSignIns.ps1
#>

[CmdletBinding()]
param(
    [switch]$DigestMode,
    [string]$CustomerDir,
    [string]$SpFolder,
    [string]$FromAddress,
    [string[]]$ToAddresses
)

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

# System settings and variables

$CustomerName = "Katz" # customer name (only used in direct script invocation)
$AdditionalToAddresses = @()  # per-audit extra recipients (only available in $DigestMode)

# Import functions

. (Join-Path $PSScriptRoot "..\..\..\..\scripts\Functions-VA-Common.ps1")

# ---------------------------------------------------------------------------
# Run tasks
# ---------------------------------------------------------------------------

# Script settings and variables

if (-not $CustomerDir) {
    $CustomerSettings = Map-Customer $CustomerName
    $CustomerDir = $CustomerSettings.Directory
    $SpFolder = $CustomerSettings.SharepointFolder
    $FromAddress = $CustomerSettings.FromAddress
}
if (-not $ToAddresses) { $ToAddresses = @("bwinklesky@servit.net") }

try {

    $Result = & (Join-Path $PSScriptRoot "..\..\scripts\Invoke-LogAudit-UserSignIns-Default.ps1") `
    -CustomerDir $CustomerDir `
    -SpFolder $SpFolder `
    -FromAddress $FromAddress `
    -ToAddresses $ToAddresses `
        -SkipEmail:$DigestMode


    if ($DigestMode) {
        return [PSCustomObject]@{
            CsvPath               = $Result.CsvPath
            TooLarge              = $Result.TooLarge
            SizeMB                = $Result.SizeMB
            AdditionalToAddresses = $AdditionalToAddresses
        }
    }
}
catch {

    Write-Host "$($_.Exception.Message)"

    exit 1

}
