<#
.SYNOPSIS
    Analyst (prototype): rough, order-of-magnitude classification of a customer's collected
    sign-in failures into "credential-relevant" (worth a human's eye) vs. routine/benign noise,
    plus a few specific candidate signals within the credential-relevant subset. Does not call
    Graph. NOT a verified malicious-actor determination - there is no IP-reputation/threat-intel
    source anywhere in this workspace, so nothing here can say "this IP is a known bad actor."
    This surfaces statistically-unusual patterns for a human to actually look at, nothing more.

.DESCRIPTION
    Mock-up per Brad's ask (2026-08-18) - not wired into an orchestrator/wrapper, no exclusion
    convention, no email.

    Most Entra sign-in failure codes are routine operational noise, not attack signals - device
    compliance blocks, expired sessions, consent prompts, tenant throttling. Bucketing every
    failure as equally "suspicious" would badly overstate the real number. Confirmed against the
    real 28MB production export this was built against: the single highest-failure-count IP
    (291 failures, 35 distinct users) turned out to be ~51% ordinary session/device noise
    (codes 50097/50140/70044/etc.) once broken down by code - not the wall-to-wall credential
    attack it looked like from a flat failure count alone.

    Buckets, using only well-documented Entra error codes (unrecognized codes fall into
    Other/Routine, not guessed at):
      - BadPassword (50126) - invalid credentials
      - AccountLocked (50053) - Entra's own lockout after repeated bad passwords - the single
        strongest signal here, since Entra itself already decided this looked like an attack
      - MfaChallengeFailed (50074, 50076) - the *password* was correct, MFA wasn't completed -
        arguably more concerning per-user than a bad password alone, since it means whoever
        tried it has (or guessed) a valid credential
      - AccountDisabled (50057) - login attempted against a disabled account - nobody legitimate
        keeps trying a known-disabled account
      - Other/Routine - everything else (device compliance, session expiry, consent, MFA
        enrollment prompts, throttling, etc.) - excluded from every signal below

    Within just the credential-relevant subset (not routine noise):
      - Non-US sign-in attempts, listed individually (small numbers expected - not a per-user
        baseline, just "not US" for a US-based org, so a legitimate traveling employee will
        also show up here)
      - IPs with 3+ distinct usernames hit (password-spray shape) - explicitly not conclusive,
        since a shared office/VPN egress IP produces the exact same shape from ordinary
        employee traffic mixed with a little real noise
      - Users with an AccountLocked or MfaChallengeFailed event - a watchlist, not a verdict

.EXAMPLE
    .\Compare-Users-SignInThreatSignals.ps1 -Directory katz -RawPath "..\data\raw\katz\202607 - EntraLogs.csv"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Directory,

    [int]$SprayDistinctUserThreshold = 3,

    [string]$RawPath,
    [string]$OutputPath
)

if (-not $RawPath)    { $RawPath    = Join-Path $PSScriptRoot "..\data\raw\$Directory\EntraUserSignIns.csv" }
if (-not $OutputPath) { $OutputPath = Join-Path $PSScriptRoot "output\$Directory\Users-SignInThreatSignals.csv" }

. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-VA-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-Formatting-Common.ps1")

$Now = Get-Date

$BadPasswordCodes = @('50126')
$AccountLockedCodes = @('50053')
$MfaChallengeFailedCodes = @('50074', '50076')
$AccountDisabledCodes = @('50057')

# --- load + classify -------------------------------------------------------------------

$Events = @(Import-Csv -LiteralPath $RawPath -Encoding UTF8)

$Classified = foreach ($Event in $Events) {

    $Code = $null
    if ($Event.EventStatus -match 'errorCode:\s*(\d+)') { $Code = $Matches[1] }
    if (-not $Code -or $Code -eq '0') { continue }  # only failures from here on

    $Country = $null
    if ($Event.Location -match 'countryOrRegion:\s*([A-Za-z]*)') { $Country = $Matches[1] }

    $Category =
        if ($Code -in $AccountLockedCodes) { "AccountLocked" }
        elseif ($Code -in $MfaChallengeFailedCodes) { "MfaChallengeFailed" }
        elseif ($Code -in $BadPasswordCodes) { "BadPassword" }
        elseif ($Code -in $AccountDisabledCodes) { "AccountDisabled" }
        else { "Other/Routine" }

    [PSCustomObject][ordered]@{
        Date     = $Now.ToString("yyyy-MM-dd")
        UPN      = $Event.UserPrincipalName
        IP       = $Event.IpAddress
        Country  = $Country
        Code     = $Code
        Category = $Category
        DateTime = $Event.CreatedDateTime
    }

}

$TotalFailures = $Classified.Count
$CredentialRelevant = @($Classified.Where({ $_.Category -ne "Other/Routine" }))

# Blank-UPN rows (confirmed live: ~34 in the real export tested against, spanning different
# apps/protocols - not one coherent identity, just Graph not always resolving a user context)
# can't usefully participate in per-user/per-IP-distinct-user grouping below - blindly grouping
# them would fabricate a single fake "user" out of several unrelated sign-ins. Counted
# separately instead of silently dropped, so the gap is visible rather than hidden.
$NoUpnCount = @($CredentialRelevant.Where({ -not $_.UPN })).Count
$CredentialRelevant = @($CredentialRelevant.Where({ $_.UPN }))

# --- signal 1: non-US attempts (within credential-relevant subset) -------------------------------------------------------------------

$ForeignAttempts = @($CredentialRelevant.Where({ $_.Country -and $_.Country -ne "US" }))

# --- signal 2: IPs hitting several distinct users (password-spray shape, not conclusive) -------------------------------------------------------------------

$SprayCandidates = @(
    $CredentialRelevant | Group-Object IP | ForEach-Object {
        $DistinctUsers = @($_.Group.UPN | Select-Object -Unique)
        if ($DistinctUsers.Count -ge $SprayDistinctUserThreshold) {
            [PSCustomObject]@{
                IP             = $_.Name
                Failures       = $_.Count
                DistinctUsers  = $DistinctUsers.Count
                SampleUsers    = ($DistinctUsers | Select-Object -First 5) -join ", "
            }
        }
    } | Sort-Object DistinctUsers -Descending
)

# --- signal 3: users with a lockout or MFA-challenge-failed event (credentials possibly known) -------------------------------------------------------------------

$Watchlist = @(
    $CredentialRelevant.Where({ $_.Category -in @("AccountLocked", "MfaChallengeFailed") }) |
    Group-Object UPN | ForEach-Object {
        [PSCustomObject]@{
            UPN                = $_.Name
            AccountLockedCount = @($_.Group.Where({ $_.Category -eq "AccountLocked" })).Count
            MfaFailedCount     = @($_.Group.Where({ $_.Category -eq "MfaChallengeFailed" })).Count
        }
    } | Sort-Object AccountLockedCount, MfaFailedCount -Descending
)

# --- output -------------------------------------------------------------------

Test-Directory (Split-Path $OutputPath -Parent)
Export-Utf8NoBomCsv -Path $OutputPath -InputObject $CredentialRelevant

$CategoryCounts = $Classified | Group-Object Category | Sort-Object Count -Descending

Write-Host "$TotalFailures total failure(s) in raw log."
Write-Host "Breakdown by category:"
foreach ($Cat in $CategoryCounts) { Write-Host "  $($Cat.Name): $($Cat.Count)" }
Write-Host ""
Write-Host "$($CredentialRelevant.Count) credential-relevant failure(s) (excludes Other/Routine)."
if ($NoUpnCount -gt 0) { Write-Host "$NoUpnCount credential-relevant failure(s) had no resolvable UPN - excluded from per-user/per-IP signals below, not counted as any single user." -ForegroundColor Yellow }
Write-Host "$($ForeignAttempts.Count) non-US credential-relevant attempt(s)."
Write-Host "$($SprayCandidates.Count) IP(s) hit $SprayDistinctUserThreshold+ distinct users (not conclusive - could be shared office/VPN egress)."
Write-Host "$($Watchlist.Count) user(s) with a lockout or MFA-challenge-failed event."
Write-Host ""
Write-Host "Credential-relevant events written to $OutputPath"

if ($ForeignAttempts.Count -gt 0) {
    Write-Host "`n--- Non-US attempts ---" -ForegroundColor Yellow
    $ForeignAttempts | Select-Object UPN, IP, Country, Category, DateTime | Format-Table -AutoSize
}
if ($SprayCandidates.Count -gt 0) {
    Write-Host "--- IPs hitting multiple users ---" -ForegroundColor Yellow
    $SprayCandidates | Format-Table -AutoSize
}
if ($Watchlist.Count -gt 0) {
    Write-Host "--- User watchlist (lockout/MFA-challenge-failed) ---" -ForegroundColor Yellow
    $Watchlist | Format-Table -AutoSize
}
