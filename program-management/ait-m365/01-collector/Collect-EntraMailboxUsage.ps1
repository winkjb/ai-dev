<#
.SYNOPSIS
    Collector: pulls the tenant's 30-day mailbox usage report via Graph API - raw and
    unfiltered (including soft-deleted mailboxes), no interpretation. Writes one raw snapshot to
    data/raw/<Directory>/. Analyst scripts (../02-analyst/Compare-MailboxSize.ps1) read this
    file rather than calling Graph directly. That Analyst also reuses
    ../01-collector/Collect-EntraLicenses.ps1's raw license catalog/assignment snapshots for
    license lookups rather than this collector re-pulling them - those files already have
    exactly the shape needed.

.DESCRIPTION
    The Graph mailbox usage report endpoint (getMailboxUsageDetail) returns CSV text directly,
    not a paginated JSON collection like every other endpoint this workspace calls - so this
    collector can't use Get-All365Results and calls Invoke-RestMethod directly instead.

    Storage is written in raw bytes, not pre-converted to GB/percentage - that conversion is
    the Analyst's job. IsDeleted is preserved on every row rather than filtered out here, since
    whether soft-deleted mailboxes should ever be flagged is a policy call, not a data-fidelity
    one.

.EXAMPLE
    .\Collect-EntraMailboxUsage.ps1 -Directory katz
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Directory,

    [string]$SettingsPath,
    [string]$OutputPath
)

if (-not $SettingsPath) { $SettingsPath = Join-Path $PSScriptRoot "..\data\reference\$Directory\M365Settings.txt" }
if (-not $OutputPath)   { $OutputPath   = Join-Path $PSScriptRoot "..\data\raw\$Directory\EntraMailboxUsage.csv" }

. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-VA-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-M365-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-Formatting-Common.ps1")

$StartTime = Get-Date

$CustomerSettings = Import-Settings -SettingsPath $SettingsPath
$Token = Get-GraphToken -CustomerSettings $CustomerSettings
$Headers = @{ Authorization = "Bearer $Token" }

Write-Host "Fetching mailbox usage report..." -ForegroundColor Cyan
$Uri = "https://graph.microsoft.com/v1.0/reports/getMailboxUsageDetail(period='D30')"
$RawReport = Invoke-RestMethod -Uri $Uri -Headers $Headers
$Mailboxes = $RawReport | ConvertFrom-Csv -Delimiter ','

$Rows = foreach ($Mailbox in $Mailboxes) {
    [PSCustomObject]@{
        DisplayName                   = $Mailbox.'Display Name'
        UPN                           = $Mailbox.'User Principal Name'
        IsDeleted                     = $Mailbox.'Is Deleted'
        HasArchive                    = $Mailbox.'Has Archive'
        StorageUsedBytes              = $Mailbox.'Storage Used (Byte)'
        ProhibitSendReceiveQuotaBytes = $Mailbox.'Prohibit Send/Receive Quota (Byte)'
    }
}

Test-Directory (Split-Path $OutputPath -Parent)
Export-Utf8NoBomCsv -Path $OutputPath -InputObject @($Rows)

$TotalSeconds = ((Get-Date) - $StartTime).TotalSeconds
Write-Host ("Wrote {0} mailbox(es) to {1} in {2:N0}s" -f $Rows.Count, $OutputPath, $TotalSeconds) -ForegroundColor Green
