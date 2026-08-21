<#
.SYNOPSIS
    Runs the zero-hit firewall policy/VIP audit against every FortiGate site under a customer's
    data/reference/<CustomerDir>/ folder, then emails one consolidated report.

.DESCRIPTION
    A "site" is any subfolder of data/reference/<CustomerDir>/ containing a FirewallSettings.txt
    (e.g. data/reference/katz/hq, data/reference/katz/harbourpost) - a customer with multiple
    FortiGates just needs one settings file per site, no other wiring. Each site is collected
    and analyzed independently (../01-collector/Collect-FirewallPolicies.ps1,
    ../02-analyst/Compare-PolicyAudit-ZeroHits.ps1); a failure on one site is caught and recorded
    rather than stopping the rest of the run.

.EXAMPLE
    .\Invoke-FirewallAudit-ZeroHits-Default.ps1 -CustomerDir katz -SpFolder Katz -FromAddress "Katz Virtual Administrator <noreply@alerts.servit.net>" -ToAddresses bwinklesky@servit.net
#>

[CmdletBinding()]
param(

    [Parameter(Mandatory)]
    [string]$CustomerDir,
    [string]$SpFolder,
    [string]$FromAddress,
    [string[]]$ToAddresses

)

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

# System settings and variables

$OutputDir = Join-Path $PSScriptRoot "..\$($CustomerDir)\output"
$OutputFile = Join-Path $OutputDir ("run-logs-{0:yyyy-MM}.log" -f (Get-Date))

# Import functions

. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-VA-Common.ps1")

# ---------------------------------------------------------------------------
# Run tasks
# ---------------------------------------------------------------------------

# Script settings and variables

$ErrorActionPreference = "Stop"
$SitesRoot = Join-Path $PSScriptRoot "..\data\reference\$($CustomerDir)"
$EmailScript = Join-Path $PSScriptRoot "..\..\..\scripts\Send-EmailMessage.ps1"
$CollectorScript = Join-Path $PSScriptRoot "..\01-collector\Collect-FirewallPolicies.ps1"
$AnalystScript = Join-Path $PSScriptRoot "..\02-analyst\Compare-PolicyAudit-ZeroHits.ps1"

# Validate output directory

Test-Directory $OutputDir

try {

    # ---------------------------------------------------------------------------
    # Beginning tasks
    # ---------------------------------------------------------------------------

    Write-ToLog -LogFile $OutputFile -Message "=== Starting $($SpFolder) zero-hit firewall audit run ==="

    if (-not (Test-Path -LiteralPath $SitesRoot)) {
        throw "No FortiGate reference data found under $SitesRoot"
    }

    $SiteDirs = Get-ChildItem -Path $SitesRoot -Directory |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "FirewallSettings.txt") }

    if ($SiteDirs.Count -eq 0) {
        throw "No site under $SitesRoot has a FirewallSettings.txt"
    }

    $Attachments = @()

    foreach ($Site in $SiteDirs) {

        $SiteDirectory = "$($CustomerDir)\$($Site.Name)"

        try {
            & $CollectorScript -Directory $SiteDirectory
            Write-ToLog -LogFile $OutputFile -Message "Collected firewall policies for $($Site.Name)"

            & $AnalystScript -Directory $SiteDirectory
            Write-ToLog -LogFile $OutputFile -Message "Generated zero-hit audit for $($Site.Name)"

            $Attachments += Join-Path $PSScriptRoot "..\02-analyst\output\$($SiteDirectory)\PolicyAudit-ZeroHits.csv"
            $Attachments += Join-Path $PSScriptRoot "..\02-analyst\output\$($SiteDirectory)\VipAudit-ZeroHits.csv"
        }
        catch {
            Write-ToLog -LogFile $OutputFile -Message "Site $($Site.Name) failed: $($_.Exception.Message)" -Level ERROR
        }

    }

    # ---------------------------------------------------------------------------
    # Send email
    # ---------------------------------------------------------------------------

    & $EmailScript -To $ToAddresses -Subject "$($SpFolder) - FortiGate Zero-Hit Policy Audit" `
        -From $FromAddress -Attachments $Attachments

    # ---------------------------------------------------------------------------
    # Ending tasks
    # ---------------------------------------------------------------------------

    Write-ToLog -LogFile $OutputFile -Message "Emailed reports to $($ToAddresses -join ', ')"
    Write-ToLog -LogFile $OutputFile -Message "=== Run completed successfully ==="

}
catch {

    Write-ToLog -LogFile $OutputFile -Message "ERROR: $($_.Exception.Message)" -Level ERROR
    Write-ToLog -LogFile $OutputFile -Message "=== Run failed ===" -Level ERROR

    # Best-effort failure notice - if this fails too (e.g. SMTP settings themselves are the
    # problem), don't let that mask the original error's exit code.
    try {
        & $EmailScript -To $ToAddresses -Subject "$($SpFolder) - FortiGate Zero-Hit Policy Audit - FAILED" `
            -From $FromAddress `
            -Body "The scheduled zero-hit firewall audit run failed: $($_.Exception.Message)`n`nSee $OutputFile on the host machine for details."
    }
    catch {
        Write-ToLog -LogFile $OutputFile -Message "Also failed to send failure notification: $($_.Exception.Message)" -Level ERROR
    }

    exit 1

}
