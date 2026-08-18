<#
.SYNOPSIS
    Analyst: cross-references a customer's collected Entra user list
    (../01-collector/Collect-EntraUsers.ps1's raw snapshot) against mailbox purpose
    (../01-collector/Collect-EntraMailboxPurpose.ps1's scoped snapshot for this audit) and
    mailbox usage (../01-collector/Collect-EntraMailboxUsage.ps1's raw snapshot) to find shared
    mailboxes that are still carrying a license, with licenses resolved from
    ../01-collector/Collect-EntraLicenses.ps1's raw catalog. Does not call Graph and does not
    email - that's the collector's and the customer wrapper's job, respectively (see
    ../katz/Invoke-MailboxAudit-LicensedShared.ps1).

.DESCRIPTION
    A mailbox is a candidate if it's licensed (non-blank AssignedSkuIds in the user snapshot)
    AND its collected mailbox purpose is exactly "shared". Storage stats come from the mailbox
    usage snapshot, resolved by UPN; a candidate with no matching usage row, or a zero storage
    quota (percentage can't be computed), is dropped - same defensive convention as
    ../02-analyst/Compare-Mailboxes-Size.ps1. Soft-deleted mailboxes (IsDeleted=True in the usage
    snapshot) are dropped too, for the same reason, even though the original
    UserAudit-LicensedSharedMailboxes-Default.ps1 monolith didn't explicitly check for it - a
    genuinely licensed shared mailbox should never be soft-deleted in practice, and this keeps
    both mailbox-usage-driven Analysts consistent.

    -ListCandidateUpns outputs just the licensed-user UPNs (computed from EntraUsers.csv alone -
    purpose isn't known yet, so this is a safe superset, not the exact "licensed AND shared"
    candidate set) and exits before doing anything else. This exists so the calling wrapper can
    pull mailbox purpose for only these UPNs (via
    ../01-collector/Collect-EntraMailboxPurpose.ps1's -Upns param) instead of the whole tenant -
    on a large tenant, checking purpose for everyone when only licensed users can ever match was
    measured costing minutes, not seconds. The "who's licensed" check lives here, in exactly one
    place, so the wrapper's pre-filter and this script's real filter can never drift out of sync
    with each other - it's the same code path both times.

    Users listed in data/reference/<Directory>/excluded-licensed-shared-mailboxes.csv (matched by
    UPN) are dropped from the findings by default. Pass -IncludeExclusions to keep them in the
    output instead, marked via an IsExcluded column - same convention as
    ../02-analyst/Compare-Groups-Temp.ps1.

.EXAMPLE
    .\Compare-Mailboxes-LicensedShared.ps1 -Directory katz -ListCandidateUpns

.EXAMPLE
    .\Compare-Mailboxes-LicensedShared.ps1 -Directory katz
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Directory,

    [string]$UsersPath,
    [string]$LicenseCatalogPath,
    [string]$MailboxPurposePath,
    [string]$MailboxUsagePath,
    [string]$ExclusionsPath,
    [string]$OutputPath,
    [switch]$IncludeExclusions,

    [switch]$ListCandidateUpns
)

if (-not $UsersPath)          { $UsersPath          = Join-Path $PSScriptRoot "..\data\raw\$Directory\EntraUsers.csv" }
if (-not $LicenseCatalogPath) { $LicenseCatalogPath = Join-Path $PSScriptRoot "..\data\raw\$Directory\EntraLicenses-Usage.csv" }
if (-not $MailboxPurposePath) { $MailboxPurposePath = Join-Path $PSScriptRoot "..\data\raw\$Directory\EntraMailboxPurpose-LicensedShared.csv" }
if (-not $MailboxUsagePath)   { $MailboxUsagePath   = Join-Path $PSScriptRoot "..\data\raw\$Directory\EntraMailboxUsage.csv" }
if (-not $ExclusionsPath)     { $ExclusionsPath     = Join-Path $PSScriptRoot "..\data\reference\$Directory\excluded-licensed-shared-mailboxes.csv" }
if (-not $OutputPath)         { $OutputPath         = Join-Path $PSScriptRoot "output\$Directory\MailboxAudit-LicensedAndShared.csv" }

. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-VA-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-M365-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-Formatting-Common.ps1")

$Now = Get-Date

# --- candidate pass (no mailbox-purpose data needed) -------------------------------------------------------------------

$Users = @(Import-Csv -LiteralPath $UsersPath -Encoding UTF8)
$Licensed = @($Users.Where({ $_.AssignedSkuIds }))

if ($ListCandidateUpns) {
    $Licensed | ForEach-Object { $_.UserPrincipalName }
    Write-Host "$($Users.Count) user(s) in raw snapshot, $($Licensed.Count) licensed candidate(s)." -ForegroundColor Cyan
    return
}

# --- flag (mailbox-purpose data needed from here on) -------------------------------------------------------------------

$Catalog = @(Import-Csv -LiteralPath $LicenseCatalogPath -Encoding UTF8)
$MailboxPurposeRows = @(Import-Csv -LiteralPath $MailboxPurposePath -Encoding UTF8)
$MailboxUsageRows = @(Import-Csv -LiteralPath $MailboxUsagePath -Encoding UTF8)
$ExclusionRows = if (Test-Path -LiteralPath $ExclusionsPath) { @(Import-Csv -LiteralPath $ExclusionsPath -Encoding UTF8) } else { @() }
$ExcludedUpns = @($ExclusionRows | ForEach-Object { $_.UPN } | Where-Object { $_ })

$SkuNameById = @{}
foreach ($License in $Catalog) { $SkuNameById[$License.SkuId] = $License.SkuPartNumber }

$SharedUpns = @($MailboxPurposeRows.Where({ $_.Purpose -eq "shared" }) | ForEach-Object { $_.UPN })

$UsageByUpn = @{}
foreach ($Mailbox in $MailboxUsageRows) { $UsageByUpn[$Mailbox.UPN] = $Mailbox }

# --- flag -------------------------------------------------------------------

$Candidates = @($Licensed.Where({ $SharedUpns -contains $_.UserPrincipalName }))

$CountExclusions = 0
$CountSkippedNoUsage = 0

$Results = foreach ($User in $Candidates) {

    $IsExcluded = $ExcludedUpns -contains $User.UserPrincipalName
    if ($IsExcluded) { $CountExclusions++ }

    if (-not $IsExcluded -or $IncludeExclusions) {

        $Mailbox = $UsageByUpn[$User.UserPrincipalName]

        if ((-not $Mailbox) -or ($Mailbox.IsDeleted -eq "True")) { $CountSkippedNoUsage++; continue }

        $StorageUsedGb = [math]::Round([double]$Mailbox.StorageUsedBytes / 1000000000, 2)
        $StorageMaxGb = [math]::Round([double]$Mailbox.ProhibitSendReceiveQuotaBytes / 1000000000, 2)
        if ($StorageMaxGb -le 0) { $CountSkippedNoUsage++; continue }
        $StoragePercentage = [math]::Round(($StorageUsedGb / $StorageMaxGb) * 100, 2)

        $UserLicenses = (($User.AssignedSkuIds -split ",") | ForEach-Object { Get-FriendlyLicenseName -sku $SkuNameById[$_] } | Sort-Object) -join ","
        $LastActivityDate = $Mailbox.LastActivityDate
        $DaysAgo = Get-DaysSince -Value $LastActivityDate -Reference $Now

        $Finding = [ordered]@{
            DisplayName       = $User.DisplayName
            UPN               = $User.UserPrincipalName
            UserLicenses      = $UserLicenses
            StorageUsedGb     = $StorageUsedGb
            StorageMaxGb      = $StorageMaxGb
            StoragePercentage = $StoragePercentage
            LastActivityDate  = $LastActivityDate
            DaysAgo           = $DaysAgo
            Issue             = "User is licensed and a shared mailbox"
            Action            = "Reclaim license"
        }
        if ($IncludeExclusions) { $Finding.IsExcluded = if ($IsExcluded) {"Y"} else {$null} }
        [PSCustomObject]$Finding

    }

}

$Results = @($Results | Sort-Object DisplayName)

Test-Directory (Split-Path $OutputPath -Parent)
Export-Utf8NoBomCsv -Path $OutputPath -InputObject $Results

Write-Host "$($Users.Count) user(s) in raw snapshot."
Write-Host "$($Candidates.Count) licensed shared mailbox(es) found."
Write-Host "$CountExclusions user(s) excluded via $(Split-Path $ExclusionsPath -Leaf)."
Write-Host "$CountSkippedNoUsage candidate(s) skipped (no usable mailbox usage data)."
Write-Host "$($Results.Count) finding(s) written to $OutputPath"
