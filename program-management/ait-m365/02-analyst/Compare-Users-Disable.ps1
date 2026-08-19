<#
.SYNOPSIS
    Analyst: compares a customer's collected Entra user list
    (../01-collector/Collect-EntraUsers.ps1's raw snapshot, with resource/shared mailboxes
    resolved from ../01-collector/Collect-EntraMailboxPurpose.ps1's scoped snapshot for this
    audit) against a staleness threshold and flags candidates for disabling. Does not call Graph
    and does not email - that's the collector's and the customer wrapper's job, respectively
    (see ../katz/Invoke-UserAccessAudit-Disable.ps1).

.DESCRIPTION
    A user is a candidate if the account is enabled, was created before the -LessThanDays
    cutoff (a brand-new account hasn't had time to log in yet, so it gets a pass), and has had
    no successful or non-interactive sign-in since the cutoff (including never having signed in
    at all). Resource/shared/room mailboxes are excluded automatically (a shared mailbox account
    never logging in interactively is expected, not stale) - matches the original script's
    dynamic exclusion via mailbox purpose. -IncludeUnlicensedUsers/-IncludeGuests default to
    $true, matching the real production wrapper's actual values - override per-call for a
    customer that wants either group left out.

    -ListCandidateUpns outputs just the enabled/date/stale-login candidate UPNs (computed from
    EntraUsers.csv alone - no mailbox-purpose data needed for this pass) and exits before doing
    anything else. This exists so the calling wrapper can pull mailbox purpose for only these
    UPNs (via ../01-collector/Collect-EntraMailboxPurpose.ps1's -Upns param) instead of the
    whole tenant - on a large tenant, checking purpose for everyone when only a small stale-login
    subset is ever relevant was measured costing minutes, not seconds. The candidate logic
    lives here, in exactly one place, so the wrapper's pre-filter and this script's real
    filter can never drift out of sync with each other - it's the same code path both times.

    -Testing (default $true, matching the original script's real production default) exists
    only for forward compatibility - the original's "real" (non-testing) branch was never
    actually implemented (its own comment read "For execution, take action on aged users (For
    Future Development)"), and the workspace's current Graph app registration is read-only
    anyway. Findings are always just flagged candidates, never a claim that an account was
    disabled.

.EXAMPLE
    .\Compare-Users-Disable.ps1 -Directory katz -ListCandidateUpns

.EXAMPLE
    .\Compare-Users-Disable.ps1 -Directory katz
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Directory,

    [int]$LessThanDays = 180,

    [string]$UsersPath,
    [string]$MailboxPurposePath,
    [string]$ExclusionsPath,
    [string]$OutputPath,

    [switch]$IncludeUnlicensedUsers = $true,
    [switch]$IncludeGuests = $true,
    [switch]$IncludeExclusions,
    [switch]$Testing = $true,

    [switch]$ListCandidateUpns
)

if (-not $UsersPath)          { $UsersPath          = Join-Path $PSScriptRoot "..\data\raw\$Directory\EntraUsers.csv" }
if (-not $MailboxPurposePath) { $MailboxPurposePath = Join-Path $PSScriptRoot "..\data\raw\$Directory\EntraMailboxPurpose-AccessDisable.csv" }
if (-not $ExclusionsPath)     { $ExclusionsPath     = Join-Path $PSScriptRoot "..\data\reference\$Directory\excluded-inactive-users.csv" }
if (-not $OutputPath)         { $OutputPath         = Join-Path $PSScriptRoot "output\$Directory\UserAudit-Disable.csv" }

. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-VA-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-M365-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-Formatting-Common.ps1")

$Now = Get-Date
$DateCutoff = $Now.AddDays(-$LessThanDays)

# --- candidate pass (no mailbox-purpose data needed) -------------------------------------------------------------------

$Users = @(Import-Csv -LiteralPath $UsersPath -Encoding UTF8)
$Enabled = @($Users.Where({ $_.AccountEnabled -eq "True" }))

$Candidates = foreach ($User in $Enabled) {

    if ($User.CreatedDate -and ([datetime]$User.CreatedDate) -ge $DateCutoff) { continue }

    $LoginDaysAgo = Get-DaysSince -Value (Get-LatestDate @($User.LastSuccessfulSignInDateTime, $User.LastNonInteractiveSignInDateTime)) -Reference $Now
    $IsStale = ($null -eq $LoginDaysAgo) -or ($LoginDaysAgo -ge $LessThanDays)
    if (-not $IsStale) { continue }

    [PSCustomObject]@{ User = $User; LoginDaysAgo = $LoginDaysAgo }

}
$Candidates = @($Candidates)

if ($ListCandidateUpns) {
    $Candidates | ForEach-Object { $_.User.UserPrincipalName }
    Write-Host "$($Enabled.Count) enabled user(s) evaluated, $($Candidates.Count) stale-login candidate(s)." -ForegroundColor Cyan
    return
}

# --- flag (mailbox-purpose data needed from here on) -------------------------------------------------------------------

$MailboxPurposeRows = @(Import-Csv -LiteralPath $MailboxPurposePath -Encoding UTF8)
$ExclusionRows = if (Test-Path -LiteralPath $ExclusionsPath) { @(Import-Csv -LiteralPath $ExclusionsPath -Encoding UTF8) } else { @() }
$ExcludedUpns = @($ExclusionRows | ForEach-Object { $_.UPN } | Where-Object { $_ })

$PurposeByUpn = @{}
foreach ($Row in $MailboxPurposeRows) { $PurposeByUpn[$Row.UPN] = $Row.Purpose }

$CountExclusions = 0
$CountResourceMailboxes = 0

$Results = foreach ($Candidate in $Candidates) {

    $User = $Candidate.User
    $LoginDaysAgo = $Candidate.LoginDaysAgo

    $Purpose = $PurposeByUpn[$User.UserPrincipalName]
    if ($Purpose -and ($Purpose -ne "user")) { $CountResourceMailboxes++; continue }

    if (-not $IncludeUnlicensedUsers -and -not $User.AssignedSkuIds) { continue }
    if (-not $IncludeGuests -and ($User.UserPrincipalName -like "*#EXT#*")) { continue }

    $IsExcluded = $ExcludedUpns -contains $User.UserPrincipalName
    if ($IsExcluded) { $CountExclusions++ }

    if (-not $IsExcluded -or $IncludeExclusions) {

        $Finding = [ordered]@{
            DisplayName                 = $User.DisplayName
            UPN                         = $User.UserPrincipalName
            CreatedDate                 = $User.CreatedDate
            LastSuccessfulLogonDate     = $User.LastSuccessfulSignInDateTime
            LastNonInteractiveLogonDate = $User.LastNonInteractiveSignInDateTime
            LoginDaysAgo                = $LoginDaysAgo
            Issue                       = if ($null -eq $LoginDaysAgo) { "No logon recorded" } else { "Last logon more than $LessThanDays days ago" }
            Action                      = "Disable user"
        }
        if ($IncludeExclusions) { $Finding.Excluded = if ($IsExcluded) { "Y" } else { $null } }
        [PSCustomObject]$Finding

        if ($Testing) { Write-Host "Testing Mode: $($User.UserPrincipalName) would be disabled." -ForegroundColor Yellow }

    }

}

$Results = @($Results | Sort-Object DisplayName)

Test-Directory (Split-Path $OutputPath -Parent)
Export-Utf8NoBomCsv -Path $OutputPath -InputObject $Results

Write-Host "$($Enabled.Count) enabled user(s) evaluated."
Write-Host "$CountResourceMailboxes resource/shared mailbox(es) excluded."
Write-Host "$CountExclusions user(s) excluded via $(Split-Path $ExclusionsPath -Leaf)."
Write-Host "$($Results.Count) stale user(s) flagged."
