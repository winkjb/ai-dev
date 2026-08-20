<#
.SYNOPSIS
    Analyst: compares a customer's collected Entra role assignments/users/licenses
    (../01-collector/Collect-EntraGroupMembers-Admins.ps1's raw snapshots) against the internal
    admin-hygiene baseline and writes flagged findings per admin role member. Does not call
    Graph and does not email - that's the collector's and the customer wrapper's job.

.DESCRIPTION
    -AdminGroups/-LessThanDays default to the standard baseline (5 roles, 90-day staleness)
    taken from the real production wrapper for Ameriserve - override per-call if a customer
    needs a different baseline.

    Each member of an audited role can be flagged with one or more Issues:
      - Account disabled - the user account itself is disabled but still holds the role
      - Account licensed - admin accounts shouldn't carry a license (reduces attack surface)
      - No logon recorded / Last logon more than N days ago - staleness, skipped entirely if
        the collector couldn't get signInActivity for this tenant (SignInActivityAvailable=N)
      - Overlapping permissions - Global Administrator AND at least one other role
      - Escalated user account - display name/UPN doesn't look like a dedicated admin account
        (no "admin" in the name, not a servit.net account, not a known service integration)

    Disabled-user members are dropped from the findings by default (they still count toward
    "Account disabled" internally but aren't written out) - pass -IncludeDisabledUsers to keep
    them. Service accounts/principals (no UPN) are always included since they can't be
    "disabled" in the same sense.

.EXAMPLE
    .\Compare-GroupMembers-Admins.ps1 -Directory katz
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Directory,

    # Baseline as of the real Ameriserve wrapper (2026-08-13) - override per-call if a customer
    # needs a different set of roles or staleness threshold.
    [string[]]$AdminGroups = @("Billing Administrator","User Administrator","Exchange Administrator","Global Administrator","Global Reader"),
    [int]$LessThanDays = 90,

    [string]$RoleAssignmentsPath,
    [string]$UsersPath,
    [string]$LicensesPath,
    [string]$OutputPath,

    # Default $true - matches Katz's confirmed real usage (2026-08-13). Owned here, not
    # forced by the orchestrator, so there's one source of truth to change later rather than
    # two places that could drift out of sync (same call as Compare-MailboxSize.ps1's
    # $MinStoragePercentage default).
    [switch]$IncludeDisabledUsers = $true
)

if (-not $RoleAssignmentsPath) { $RoleAssignmentsPath = Join-Path $PSScriptRoot "..\data\raw\$Directory\EntraRoles-Admins.csv" }
if (-not $UsersPath)           { $UsersPath           = Join-Path $PSScriptRoot "..\data\raw\$Directory\EntraUsers-Admins.csv" }
if (-not $LicensesPath)        { $LicensesPath         = Join-Path $PSScriptRoot "..\data\raw\$Directory\EntraLicenses-Admins.csv" }
if (-not $OutputPath)          { $OutputPath           = Join-Path $PSScriptRoot "output\$Directory\GroupAudit-Admins.csv" }

. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-VA-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-M365-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-Formatting-Common.ps1")

$Now = Get-Date

# --- load -----------------------------------------------------------------

$Licenses = @(Import-Csv -LiteralPath $LicensesPath -Encoding UTF8)
$Assignments = @(Import-Csv -LiteralPath $RoleAssignmentsPath -Encoding UTF8)
$Users = @(Import-Csv -LiteralPath $UsersPath -Encoding UTF8)

$SkuNameById = @{}
foreach ($License in $Licenses) { $SkuNameById[$License.SkuId] = $License.SkuPartNumber }

$UserByUpn = @{}
foreach ($User in $Users) { $UserByUpn[$User.UserPrincipalName] = $User }

# Every role a UPN holds, across ALL roles in the raw snapshot (not just the ones being
# audited) - the "Overlapping permissions" check needs the full picture, matching the
# original script's full-directory scope.
$RoleNamesByUpn = @{}
foreach ($Assignment in $Assignments) {
    if ($Assignment.UPN) { Add-ToIndex -Index $RoleNamesByUpn -Key $Assignment.UPN -Value $Assignment.RoleName }
}

$AssignmentsByRole = @{}
foreach ($Assignment in $Assignments) { Add-ToIndex -Index $AssignmentsByRole -Key $Assignment.RoleName -Value $Assignment }

# Collector-level fallback flag (identical on every row) - whether signInActivity was available
# for this pull. Default true (apply staleness checks) if there were no users at all to read it from.
$SignInActivityAvailable = if ($Users) { ($Users[0].SignInActivityAvailable -eq "Y") } else { $true }

# --- audit ------------------------------------------------------------------

$CountGroups = 0

$Results = foreach ($Group in $AdminGroups) {

    $CountGroups++
    $Members = $AssignmentsByRole[$Group]

    foreach ($Member in $Members) {

        $UPN = $Member.UPN
        $DisplayName = $Member.DisplayName
        $UserDetails = if ($UPN) { $UserByUpn[$UPN] } else { $null }
        $AdminType = if ($UPN) { "User" } else { $null }
        $IsServiceAccount = ($AdminType -ne "User")

        $Issues = [System.Collections.Generic.List[string]]::new()

        $UserEnabled = (($AdminType -eq "User") -and ($UserDetails.AccountEnabled -eq "True"))
        if (($AdminType -eq "User") -and (-not $UserEnabled)) { $Issues.Add("Account disabled") }

        if ($UserEnabled -or $IsServiceAccount -or $IncludeDisabledUsers) {

            if ($UserDetails.AssignedSkuIds) {
                $UserLicenses = (($UserDetails.AssignedSkuIds -split ",") | ForEach-Object { Get-FriendlyLicenseName -sku $SkuNameById[$_] } | Sort-Object) -join ","
            } else {
                $UserLicenses = $null
            }

            if (($AdminType -eq "User") -and $UserLicenses) { $Issues.Add("Account licensed") }

            $CreatedDate = $UserDetails.CreatedDate
            $DaysAgo = Get-DaysSince -Value $CreatedDate -Reference $Now
            $LastSuccessful = $UserDetails.LastSuccessfulSignInDateTime
            $LastNonInteractive = $UserDetails.LastNonInteractiveSignInDateTime
            $LoginDaysAgo = Get-DaysSince -Value (Get-LatestDate @($LastSuccessful, $LastNonInteractive)) -Reference $Now

            if ($SignInActivityAvailable) {
                if (($AdminType -eq "User") -and ($null -eq $LoginDaysAgo)) { $Issues.Add("No logon recorded") }
                if (($AdminType -eq "User") -and ($null -ne $LoginDaysAgo) -and ($LoginDaysAgo -ge $LessThanDays)) { $Issues.Add("Last logon more than $LessThanDays days ago") }
            }

            if (($AdminType -eq "User") -and ($Group -eq "Global Administrator") -and (@($RoleNamesByUpn[$UPN]).Count -gt 1)) { $Issues.Add("Overlapping permissions") }
            if (($AdminType -eq "User") -and ($DisplayName -notmatch "Proofpoint Essentials|Quest On Demand") -and ($DisplayName -notlike "*admin*") -and ($UPN -notmatch "admin|servit")) { $Issues.Add("Escalated user account") }

            [PSCustomObject][ordered]@{
                Date                         = $Now.ToString("yyyy-MM-dd")
                Group                        = $Group
                DisplayName                  = $DisplayName
                UPN                          = $UPN
                CreatedDate                  = $CreatedDate
                DaysAgo                      = $DaysAgo
                LastSuccessfulLogonDate      = $LastSuccessful
                LastNonInteractiveLogonDate  = $LastNonInteractive
                LoginDaysAgo                 = $LoginDaysAgo
                UserLicenses                 = $UserLicenses
                AccountEnabled               = if ($AdminType -eq "User") { $UserEnabled } else { $null }
                Issue                        = $Issues -join ","
            }

        }

    }

}

$Results = @($Results | Sort-Object Group, DisplayName)

Test-Directory (Split-Path $OutputPath -Parent)
Export-Utf8NoBomCsv -Path $OutputPath -InputObject $Results

Write-Host "$($Results.Count) admin role membership(s) identified across $CountGroups group(s)."
if (-not $SignInActivityAvailable) { Write-Host "Note: signInActivity wasn't available for this pull - logon-staleness findings were skipped." -ForegroundColor Yellow }
Write-Host "Findings written to $OutputPath"
