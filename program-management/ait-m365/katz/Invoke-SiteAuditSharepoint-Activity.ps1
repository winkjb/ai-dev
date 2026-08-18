<#
.SYNOPSIS
    Unattended entry point for Katz's SharePoint activity audit - runs the collector then the
    analyst and emails the findings. Meant to be called from a scheduled task; logs to
    output/run-logs-{yyyy-MM}.log (shared with Katz's other audits, one file per month) since
    nobody's watching the console.

.EXAMPLE
    .\Invoke-SiteAuditSharepoint-Activity.ps1
#>

[CmdletBinding()]
param()

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

# Import functions

. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-VA-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-M365-Common.ps1")

# System settings and variables

# TODO: swap to automation@alerts.servit.net once this is running unattended long-term.
$ToAddresses = @("bwinklesky@servit.net")
$CustomerInfo = Map-Customer -CustomerName "Katz"
$FromEmail = "Katz Virtual Administrator <noreply@alerts.servit.net>"
$OutputDir = Join-Path $PSScriptRoot "output"
$OutputFile = Join-Path $OutputDir ("run-logs-{0:yyyy-MM}.log" -f (Get-Date))

# ---------------------------------------------------------------------------
# Run tasks
# ---------------------------------------------------------------------------

Test-Directory $OutputDir

try {

    & (Join-Path $PSScriptRoot "..\scripts\Invoke-SiteAuditSharepoint-Activity-Default.ps1") `
        -CustomerDir $CustomerInfo.Directory -SpFolder $CustomerInfo.SharepointFolder -FromAddress $FromEmail -ToAddresses $ToAddresses

}
catch {

    Write-Host "$($_.Exception.Message)"

    exit 1

}
