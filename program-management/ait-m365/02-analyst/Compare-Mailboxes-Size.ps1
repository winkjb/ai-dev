<#
.SYNOPSIS
    Analyst: compares a customer's collected mailbox usage
    (../01-collector/Collect-EntraMailboxUsage.ps1's raw snapshot) against a storage-percentage
    threshold and writes one row per mailbox at or over it, with each mailbox's licenses
    resolved from ../01-collector/Collect-EntraLicenses.ps1's raw license snapshots. Does not
    call Graph and does not email - that's the collector's and the customer wrapper's job,
    respectively (see ../katz/Invoke-MailboxAudit-Size.ps1).

.DESCRIPTION
    Soft-deleted mailboxes (IsDeleted=True in the raw snapshot) are always dropped - matches the
    original katz/Invoke-MailboxAudit-Size-Default.ps1 script's unconditional behavior (no
    switch ever kept them). Mailboxes with a zero storage quota (StoragePercentage can't be
    computed) are always dropped too - the original technically could include them when no
    threshold was passed, an artifact of PowerShell comparing $null -ge 0 as true rather than a
    deliberate design.

    -MinStoragePercentage defaults to 75 - Brad's confirmed real-world value for Katz (2026-08-16)
    and, absent any customer-specific reason otherwise, the baseline going forward (same pattern
    as ../02-analyst/Compare-GroupMembers-Admins.ps1's -LessThanDays default) - override per-call for
    a customer that needs a different threshold. This is a deliberate, documented default, unlike
    the original script's $StorageMoreThan param, which had no default and silently fell back to
    0 (flagging nearly every mailbox) if the caller simply forgot to pass it.

.EXAMPLE
    .\Compare-Mailboxes-Size.ps1 -Directory katz
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Directory,

    [double]$MinStoragePercentage = 75,

    [string]$MailboxPath,
    [string]$LicenseCatalogPath,
    [string]$LicenseAssignmentsPath,
    [string]$OutputPath
)

if (-not $MailboxPath)            { $MailboxPath            = Join-Path $PSScriptRoot "..\data\raw\$Directory\EntraMailboxUsage.csv" }
if (-not $LicenseCatalogPath)     { $LicenseCatalogPath     = Join-Path $PSScriptRoot "..\data\raw\$Directory\EntraLicenses-Usage.csv" }
if (-not $LicenseAssignmentsPath) { $LicenseAssignmentsPath = Join-Path $PSScriptRoot "..\data\raw\$Directory\EntraLicenses-Assignment.csv" }
if (-not $OutputPath)             { $OutputPath             = Join-Path $PSScriptRoot "output\$Directory\MailboxAudit-Size.csv" }

. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-VA-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-M365-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-Formatting-Common.ps1")

# --- load -----------------------------------------------------------------

$Mailboxes = @(Import-Csv -LiteralPath $MailboxPath -Encoding UTF8)
$Catalog = @(Import-Csv -LiteralPath $LicenseCatalogPath -Encoding UTF8)
$Assignments = @(Import-Csv -LiteralPath $LicenseAssignmentsPath -Encoding UTF8)

$SkuNameById = @{}
foreach ($License in $Catalog) { $SkuNameById[$License.SkuId] = $License.SkuPartNumber }

$SkuIdsByUpn = @{}
foreach ($Assignment in $Assignments) { Add-ToIndex -Index $SkuIdsByUpn -Key $Assignment.UPN -Value $Assignment.SkuId }

# --- audit ------------------------------------------------------------------

$CountMailboxes = 0

$Results = foreach ($Mailbox in $Mailboxes) {

    if ($Mailbox.IsDeleted -eq "True") { continue }

    $CountMailboxes++

    $StorageUsedGb = [math]::Round([double]$Mailbox.StorageUsedBytes / 1000000000, 2)
    $StorageMaxGb = [math]::Round([double]$Mailbox.ProhibitSendReceiveQuotaBytes / 1000000000, 2)
    $StoragePercentage = if ($StorageMaxGb -gt 0) { [math]::Round(($StorageUsedGb / $StorageMaxGb) * 100, 2) } else { $null }

    if (($null -ne $StoragePercentage) -and ($StoragePercentage -ge $MinStoragePercentage)) {

        # Not wrapped in @() - a UPN with no assignments means this lookup returns $null, and
        # `foreach ($x in $null)`/`$null | ForEach-Object` are safe zero-iteration no-ops.
        $SkuIds = $SkuIdsByUpn[$Mailbox.UPN]
        $UserLicenses = (($SkuIds | ForEach-Object { Get-FriendlyLicenseName -sku $SkuNameById[$_] }) | Sort-Object) -join ","

        [PSCustomObject][ordered]@{
            DisplayName       = $Mailbox.DisplayName
            UPN               = $Mailbox.UPN
            UserLicenses      = $UserLicenses
            HasArchive        = $Mailbox.HasArchive
            StorageUsedGb     = $StorageUsedGb
            StorageMaxGb      = $StorageMaxGb
            StoragePercentage = $StoragePercentage
        }

    }

}

$Results = @($Results | Sort-Object StoragePercentage -Descending)

Test-Directory (Split-Path $OutputPath -Parent)
Export-Utf8NoBomCsv -Path $OutputPath -InputObject $Results

Write-Host "$CountMailboxes mailbox(es) audited (excluding deleted)."
Write-Host "$($Results.Count) mailbox(es) at or over $MinStoragePercentage% usage."
Write-Host "Findings written to $OutputPath"
