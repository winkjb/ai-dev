<#
.SYNOPSIS
    Unattended entry point for Katz's SharePoint disable audit - runs the collector then the
    analyst and emails the findings. Meant to be called from a scheduled task.

.EXAMPLE
    .\Invoke-SiteAuditSharepoint-Disable.ps1
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

$CustomerName = "Katz" # customer name (not used in $DigestMode)
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

    $Result = & (Join-Path $PSScriptRoot "..\..\scripts\Invoke-SiteAuditSharepoint-Disable-Default.ps1") `
    -CustomerDir $CustomerDir `
    -SpFolder $SpFolder `
    -FromAddress $FromAddress `
    -ToAddresses $ToAddresses `
        -SkipEmail:$DigestMode


    if ($DigestMode) {
        return [PSCustomObject]@{
            CsvPath               = $Result
            AdditionalToAddresses = $AdditionalToAddresses
        }
    }
}
catch {

    Write-Host "$($_.Exception.Message)"

    exit 1

}
