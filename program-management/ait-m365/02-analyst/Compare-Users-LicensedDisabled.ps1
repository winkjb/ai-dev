<#
.SYNOPSIS
    Analyst: compares a customer's collected Entra user list
    (../01-collector/Collect-EntraUsers.ps1's raw snapshot) for accounts that are both disabled
    and still licensed, with each user's licenses resolved from
    ../01-collector/Collect-EntraLicenses.ps1's raw catalog and mailbox purpose resolved from
    ../01-collector/Collect-EntraMailboxPurpose.ps1's scoped snapshot for this audit. Does not
    call Graph and does not email - that's the collector's and the customer wrapper's job,
    respectively (see ../katz/Invoke-UserAudit-LicensedDisabled.ps1).

.DESCRIPTION
    IsSharedMailbox is informational, not a filter - it flags whether the disabled+licensed
    account is actually a resource/shared/room-type mailbox (purpose other than "user"), which
    is a different remediation than a genuinely stale disabled user account, but both still get
    reported since the license is still being consumed either way. Matches the original
    UserAudit-LicensedAndDisabled-Default.ps1 monolith's behavior, which computed this same flag
    but never used it to exclude rows.

    Users listed in data/reference/<Directory>/excluded-licensed-disabled-users.csv (matched by
    UPN) are dropped from the findings by default. Pass -IncludeExclusions to keep them in the
    output instead, marked via an IsExcluded column - same convention as
    ../02-analyst/Compare-Groups-Temp.ps1.

    -ListCandidateUpns outputs just the disabled+licensed candidate UPNs (computed from
    EntraUsers.csv alone - no mailbox-purpose data needed for this pass) and exits before doing
    anything else. This exists so the calling wrapper can pull mailbox purpose for only these
    UPNs (via ../01-collector/Collect-EntraMailboxPurpose.ps1's -Upns param) instead of the
    whole tenant - same two-pass pattern as ../02-analyst/Compare-Users-Disable.ps1's
    -ListCandidateUpns. The candidate logic lives here, in exactly one place, so the wrapper's
    pre-filter and this script's real filter can never drift out of sync with each other - it's
    the same code path both times.

.EXAMPLE
    .\Compare-Users-LicensedDisabled.ps1 -Directory katz -ListCandidateUpns

.EXAMPLE
    .\Compare-Users-LicensedDisabled.ps1 -Directory katz
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Directory,

    [string]$UsersPath,
    [string]$LicenseCatalogPath,
    [string]$MailboxPurposePath,
    [string]$ExclusionsPath,
    [string]$OutputPath,
    [switch]$IncludeExclusions,

    [switch]$ListCandidateUpns
)

if (-not $UsersPath)          { $UsersPath          = Join-Path $PSScriptRoot "..\data\raw\$Directory\EntraUsers.csv" }
if (-not $LicenseCatalogPath) { $LicenseCatalogPath = Join-Path $PSScriptRoot "..\data\raw\$Directory\EntraLicenses-Usage.csv" }
if (-not $MailboxPurposePath) { $MailboxPurposePath = Join-Path $PSScriptRoot "..\data\raw\$Directory\EntraMailboxPurpose-LicensedDisabled.csv" }
if (-not $ExclusionsPath)     { $ExclusionsPath     = Join-Path $PSScriptRoot "..\data\reference\$Directory\excluded-licensed-disabled-users.csv" }
if (-not $OutputPath)         { $OutputPath         = Join-Path $PSScriptRoot "output\$Directory\UserAudit-LicensedAndDisabled.csv" }

. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-VA-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-M365-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-Formatting-Common.ps1")

$Now = Get-Date

# --- candidate pass (no mailbox-purpose data needed) -------------------------------------------------------------------

$Users = @(Import-Csv -LiteralPath $UsersPath -Encoding UTF8)
$Candidates = @($Users.Where({ ($_.AccountEnabled -eq "False") -and $_.AssignedSkuIds }))

if ($ListCandidateUpns) {
    $Candidates | ForEach-Object { $_.UserPrincipalName }
    Write-Host "$($Users.Count) user(s) in raw snapshot, $($Candidates.Count) disabled+licensed candidate(s)." -ForegroundColor Cyan
    return
}

# --- flag (mailbox-purpose data needed from here on) -------------------------------------------------------------------

$Catalog = @(Import-Csv -LiteralPath $LicenseCatalogPath -Encoding UTF8)
$MailboxPurposeRows = @(Import-Csv -LiteralPath $MailboxPurposePath -Encoding UTF8)
$ExclusionRows = if (Test-Path -LiteralPath $ExclusionsPath) { @(Import-Csv -LiteralPath $ExclusionsPath -Encoding UTF8) } else { @() }
$ExcludedUpns = @($ExclusionRows | ForEach-Object { $_.UPN } | Where-Object { $_ })

$SkuNameById = @{}
foreach ($License in $Catalog) { $SkuNameById[$License.SkuId] = $License.SkuPartNumber }

$PurposeByUpn = @{}
foreach ($Row in $MailboxPurposeRows) { $PurposeByUpn[$Row.UPN] = $Row.Purpose }

$CountExclusions = 0

$Results = foreach ($User in $Candidates) {

    $IsExcluded = $ExcludedUpns -contains $User.UserPrincipalName
    if ($IsExcluded) { $CountExclusions++ }

    if (-not $IsExcluded -or $IncludeExclusions) {

        $UserLicenses = (($User.AssignedSkuIds -split ",") | ForEach-Object { Get-FriendlyLicenseName -sku $SkuNameById[$_] } | Sort-Object) -join ","
        $Purpose = $PurposeByUpn[$User.UserPrincipalName]
        $IsSharedMailbox = [bool]($Purpose -and ($Purpose -ne "user"))

        $CreatedDate = $User.CreatedDate
        $DaysAgo = Get-DaysSince -Value $CreatedDate -Reference $Now
        $LoginDaysAgo = Get-DaysSince -Value (Get-LatestDate @($User.LastSuccessfulSignInDateTime, $User.LastNonInteractiveSignInDateTime)) -Reference $Now

        $Finding = [ordered]@{
            Date                          = $Now.ToString("yyyy-MM-dd")
            DisplayName                  = $User.DisplayName
            UPN                          = $User.UserPrincipalName
            AccountEnabled               = $User.AccountEnabled
            UserLicenses                 = $UserLicenses
            IsSharedMailbox              = $IsSharedMailbox
            CreatedDate                  = $CreatedDate
            DaysAgo                      = $DaysAgo
            LastSuccessfulLogonDate      = $User.LastSuccessfulSignInDateTime
            LastNonInteractiveLogonDate  = $User.LastNonInteractiveSignInDateTime
            LoginDaysAgo                 = $LoginDaysAgo
            Issue                        = "User is licensed and disabled"
            Action                       = "Reclaim license"
        }
        if ($IncludeExclusions) { $Finding.IsExcluded = if ($IsExcluded) {"Y"} else {$null} }
        [PSCustomObject]$Finding

    }

}

$Results = @($Results | Sort-Object DisplayName)

Test-Directory (Split-Path $OutputPath -Parent)
Export-Utf8NoBomCsv -Path $OutputPath -InputObject $Results

Write-Host "$($Users.Count) user(s) in raw snapshot."
Write-Host "$($Candidates.Count) disabled+licensed user(s) found."
Write-Host "$CountExclusions user(s) excluded via $(Split-Path $ExclusionsPath -Leaf)."
Write-Host "$($Results.Count) finding(s) written to $OutputPath"
