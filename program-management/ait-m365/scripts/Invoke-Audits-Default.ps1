<#
.SYNOPSIS
    Runs every audit in a customer's katz/<cadence>/ folder (e.g. katz/monthly/, katz/quarterly/)
    and emails one consolidated report - only findings CSVs that actually have rows are attached.

.DESCRIPTION
    Which audits a customer runs, and at what cadence, is driven entirely by which per-audit
    wrapper files exist in that customer's cadence subfolder - no separate manifest/override
    file. A customer who doesn't run a given audit simply has no wrapper for it; a customer
    running something at a non-standard cadence has their wrapper in a different cadence folder
    than the norm; a one-off personalized audit is just an extra wrapper pointing at its own
    Collector/Analyst, no shared file touched.

    Each wrapper is invoked with -DigestMode plus this script's already-resolved -CustomerDir
    -SpFolder -FromAddress -ToAddresses, so the same Map-Customer lookup this script's own
    wrapper already did isn't repeated once per audit. -DigestMode forwards to the audit's
    Invoke-*-Default.ps1 as -SkipEmail - that skips the per-audit email and returns
    { CsvPath, AdditionalToAddresses } instead. A per-audit failure is caught and logged; it
    does not stop the rest of the digest. Each wrapper still has its own hardcoded fallback for
    all four values (used only when it's run standalone, with no arguments).

    A wrapper's AdditionalToAddresses (declared in that one customer's one wrapper file - see
    e.g. ../katz/quarterly/Invoke-MailboxAudit-Size.ps1's own -MinStoragePercentage override for
    the same per-customer-per-audit pattern) is empty by default. When set and that audit has
    findings, its CSV also goes out as its own small side-email to those recipients, in addition
    to being included in the main digest - it never replaces the main digest's inclusion.

.EXAMPLE
    .\Invoke-Audits-Default.ps1 -CustomerDir katz -Cadence Monthly -SpFolder Katz -FromAddress "Katz Virtual Administrator <noreply@alerts.servit.net>" -ToAddresses bwinklesky@servit.net
#>

[CmdletBinding()]
param(

    [Parameter(Mandatory)]
    [string]$CustomerDir,

    [Parameter(Mandatory)]
    [ValidateSet("Monthly", "Monthly-End", "Quarterly")]
    [string]$Cadence,

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
$EmailScript = Join-Path $PSScriptRoot "..\..\..\scripts\Send-EmailMessage.ps1"
$CadenceDir = Join-Path $PSScriptRoot "..\$($CustomerDir)\$($Cadence.ToLower())"

# Validate output directory

Test-Directory $OutputDir

try {

    # ---------------------------------------------------------------------------
    # Beginning tasks
    # ---------------------------------------------------------------------------

    Write-ToLog -LogFile $OutputFile -Message "=== Starting $($SpFolder) $($Cadence) digest run ==="

    if (-not (Test-Path -LiteralPath $CadenceDir)) {
        throw "No $($Cadence) folder found for this customer: $CadenceDir"
    }

    $AuditWrappers = Get-ChildItem -Path $CadenceDir -Filter "Invoke-*.ps1" -File

    if ($AuditWrappers.Count -eq 0) {
        throw "No audit wrappers found under $CadenceDir"
    }

    $Attachments = @()
    $FailedAudits = @()
    $SideEmails = @()

    foreach ($Wrapper in $AuditWrappers) {

        try {
            $Result = & $Wrapper.FullName -DigestMode -CustomerDir $CustomerDir -SpFolder $SpFolder -FromAddress $FromAddress -ToAddresses $ToAddresses
            $CsvPath = $Result.CsvPath
            $ExtraAddresses = @($Result.AdditionalToAddresses | Where-Object { $_ })

            if ($CsvPath) {
                $Rows = @(Import-Csv -LiteralPath $CsvPath -Encoding UTF8)
                if ($Rows.Count -gt 0) {
                    $Attachments += $CsvPath

                    if ($ExtraAddresses.Count -gt 0) {
                        $SideEmails += [PSCustomObject]@{
                            AuditName = $Wrapper.BaseName -replace '^Invoke-', ''
                            CsvPath   = $CsvPath
                            To        = $ExtraAddresses
                        }
                    }
                }
            }

            Write-ToLog -LogFile $OutputFile -Message "Ran $($Wrapper.BaseName)"
        }
        catch {
            Write-ToLog -LogFile $OutputFile -Message "$($Wrapper.BaseName) failed: $($_.Exception.Message)" -Level ERROR
            $FailedAudits += $Wrapper.BaseName
        }

    }

    # ---------------------------------------------------------------------------
    # Send digest email
    # ---------------------------------------------------------------------------

    # Power Automate parses this block to route results emails to the right customer -
    # required on any email carrying findings attachments, not just cosmetic.
    $TriggerBlock = "##############################<br>`nSource: Virtual Administrator<br>`nCustomer Folder: $($SpFolder)<br>`n##############################<br>"

    $Body = if ($Attachments.Count -eq 0) {
        "No findings across $($AuditWrappers.Count) $($Cadence.ToLower()) audit(s) for $($SpFolder) - all as expected."
    } else {
        "See attached report(s). $($Attachments.Count) of $($AuditWrappers.Count) $($Cadence.ToLower()) audit(s) had findings.<br><br>$TriggerBlock"
    }
    if ($FailedAudits.Count -gt 0) {
        $Body += "`n`nNote: $($FailedAudits.Count) audit(s) failed to run and are not reflected above: $($FailedAudits -join ', ')."
    }

    & $EmailScript -To $ToAddresses -Subject "$($SpFolder) - $($Cadence) M365 Audit Digest" `
        -From $FromAddress -Attachments $Attachments -Body $Body

    Write-ToLog -LogFile $OutputFile -Message "Emailed digest to $($ToAddresses -join ', ')"

    # ---------------------------------------------------------------------------
    # Send additional-recipient emails - in addition to the digest
    # ---------------------------------------------------------------------------

    foreach ($SideEmail in $SideEmails) {
        try {
            & $EmailScript -To $SideEmail.To -Subject "$($SpFolder) - $($SideEmail.AuditName) Audit" `
                -From $FromAddress -Attachments @($SideEmail.CsvPath)
            Write-ToLog -LogFile $OutputFile -Message "Emailed $($SideEmail.AuditName) to additional recipient(s) $($SideEmail.To -join ', ')"
        }
        catch {
            Write-ToLog -LogFile $OutputFile -Message "Failed to email $($SideEmail.AuditName) to additional recipient(s): $($_.Exception.Message)" -Level ERROR
        }
    }

    # ---------------------------------------------------------------------------
    # Ending tasks
    # ---------------------------------------------------------------------------

    Write-ToLog -LogFile $OutputFile -Message "=== Run completed successfully ==="

}
catch {

    Write-ToLog -LogFile $OutputFile -Message "ERROR: $($_.Exception.Message)" -Level ERROR
    Write-ToLog -LogFile $OutputFile -Message "=== Run failed ===" -Level ERROR

    # Best-effort failure notice - if this fails too (e.g. SMTP settings themselves are the
    # problem), don't let that mask the original error's exit code.
    try {
        & $EmailScript -To $ToAddresses -Subject "$($SpFolder) - $($Cadence) M365 Audit Digest - FAILED" `
            -From $FromAddress `
            -Body "The scheduled $($Cadence) digest run failed: $($_.Exception.Message)`n`nSee $OutputFile on the host machine for details."
    }
    catch {
        Write-ToLog -LogFile $OutputFile -Message "Also failed to send failure notification: $($_.Exception.Message)" -Level ERROR
    }

    exit 1

}
