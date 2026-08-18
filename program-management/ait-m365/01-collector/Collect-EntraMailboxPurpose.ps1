<#
.SYNOPSIS
    Collector: pulls each mail-enabled user's mailbox purpose (user/shared/room/equipment/etc.)
    via Graph API's batch endpoint - raw and unfiltered, no interpretation. Writes one raw
    snapshot to data/raw/<Directory>/EntraMailboxPurpose.csv. Analyst scripts
    (../02-analyst/Compare-Users-LicensedDisabled.ps1, ../02-analyst/Compare-Mailboxes-LicensedShared.ps1)
    read this file rather than calling Graph directly - one flags any licensed+disabled user
    whose mailbox purpose isn't "user" (informational - it's a resource mailbox carrying a
    license, a different remediation than a genuinely stale disabled account), the other flags
    specifically "shared" mailboxes carrying a license.

.DESCRIPTION
    mailboxSettings has no bulk/list endpoint - it must be queried per user. Pulls its own
    minimal id/UPN list directly from Graph (rather than reading
    ../01-collector/Collect-EntraUsers.ps1's raw snapshot) so this collector can run standalone,
    matching this workspace's collector-independence precedent (see Collect-EntraLicenses.ps1's
    .DESCRIPTION). Requests are batched 20 at a time via Graph's `$batch` endpoint (matches the
    original katz/UserAudit-LicensedAndDisabled-Default.ps1 / UserAudit-LicensedSharedMailboxes-Default.ps1
    scripts' batch size) to stay well under the batch endpoint's 20-subrequest limit.

    Only users with a successful (200) mailboxSettings response AND a non-blank userPurpose are
    written - a user with no mailbox at all (no permanent-failure response, or an empty
    userPurpose) has nothing meaningful to report. Output is keyed by UPN, not the Graph object
    id, so it joins directly against every other raw snapshot in this workspace without a
    separate id lookup.

    Individual batch sub-responses that come back 429/503/504 are retried up to 4 times,
    honoring the sub-response's own Retry-After header when present. A user still failing after
    all retries is logged as a warning (not silently dropped) so a gap is at least visible,
    rather than an Analyst quietly under-reporting.

    -Upns scopes the check to only the given UPNs instead of every user in the tenant - on a
    large customer, checking mailbox purpose for everyone when a downstream Analyst only cares
    about a much smaller subset (e.g. licensed users, or stale-login candidates) was measured
    costing minutes instead of seconds. Still always resolves object ids first (the "list all
    users" call was never the expensive part - the per-user mailboxSettings batch calls were),
    then batches by id filtered down to the requested UPNs, rather than batching by UPN
    directly. That's deliberate, not incidental: confirmed live that mailboxSettings for a
    "shared"-purpose mailbox can return a *persistent* 503 "MailboxInfoStale" when queried by
    UPN - not transient, still failing after 4 retries over 46 seconds - while the identical
    request by object id succeeds every time. Since these audits specifically target
    resource/shared mailboxes, that failure mode would hit exactly the accounts they most need
    to see, so id-based batching is required for correctness, not just an optimization choice.
    Omit -Upns for the original full-tenant behavior (used by audits that need everyone, e.g.
    ../02-analyst/Compare-Users-Hr.ps1/../02-analyst/Compare-Users-Temp.ps1).

.EXAMPLE
    .\Collect-EntraMailboxPurpose.ps1 -Directory katz

.EXAMPLE
    .\Collect-EntraMailboxPurpose.ps1 -Directory katz -Upns @("user1@katz.com","user2@katz.com") -OutputPath ..\data\raw\katz\EntraMailboxPurpose-Scoped.csv
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Directory,

    [string[]]$Upns,

    [string]$SettingsPath,
    [string]$OutputPath,
    [int]$BatchSize = 20
)

if (-not $SettingsPath) { $SettingsPath = Join-Path $PSScriptRoot "..\data\reference\$Directory\M365Settings.txt" }
if (-not $OutputPath)   { $OutputPath   = Join-Path $PSScriptRoot "..\data\raw\$Directory\EntraMailboxPurpose.csv" }

. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-VA-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-M365-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-Formatting-Common.ps1")

$StartTime = Get-Date

$CustomerSettings = Import-Settings -SettingsPath $SettingsPath
$Token = Get-GraphToken -CustomerSettings $CustomerSettings
$Headers = @{ Authorization = "Bearer $Token" }

# Always resolve id/UPN pairs first - one cheap list call, not the expensive part - then batch
# by id. ContainsKey, not just "if ($Upns)" - an explicitly-passed empty array (a real "zero
# candidates" result from a caller's -ListCandidateUpns pass) is falsy in PowerShell and would
# otherwise be silently misread as "not scoped at all," falling through to a full-tenant pull.
$IsScoped = $PSBoundParameters.ContainsKey('Upns')

Write-Host "Fetching users..." -ForegroundColor Cyan
$Uri = "https://graph.microsoft.com/v1.0/users?`$select=id,userPrincipalName"
$AllUsers = Get-All365Results -Uri $Uri -Headers $Headers
$UpnById = @{}
foreach ($User in $AllUsers) { $UpnById[$User.id] = $User.userPrincipalName }

if ($IsScoped) {
    $UpnSet = @{}
    foreach ($Upn in $Upns) { $UpnSet[$Upn] = $true }
    $RequestKeys = @($AllUsers | Where-Object { $UpnSet.ContainsKey($_.userPrincipalName) } | ForEach-Object { $_.id })
    Write-Host "Fetching mailbox purpose for $($RequestKeys.Count) scoped user(s)..." -ForegroundColor Cyan
} else {
    $RequestKeys = @($AllUsers | ForEach-Object { $_.id })
    Write-Host "Fetching mailbox purpose for $($RequestKeys.Count) user(s)..." -ForegroundColor Cyan
}

$Rows = @()
$MaxAttempts = 4

for ($i = 0; $i -lt $RequestKeys.Count; $i += $BatchSize) {

    $PendingKeys = $RequestKeys[$i..([math]::Min($i + $BatchSize - 1, $RequestKeys.Count - 1))]
    $Attempt = 0

    while ($PendingKeys.Count -gt 0 -and $Attempt -lt $MaxAttempts) {

        $Attempt++

        $Requests = foreach ($Key in $PendingKeys) {
            @{
                id     = $Key
                method = "GET"
                url    = "/users/$Key/mailboxSettings?`$select=userPurpose"
            }
        }

        $Body = @{ requests = @($Requests) } | ConvertTo-Json -Depth 5
        $ApiResponse = Invoke-RestMethod -Method Post -Uri "https://graph.microsoft.com/v1.0/`$batch" -Headers $Headers -Body $Body -ContentType "application/json"

        $RetryKeys = [System.Collections.Generic.List[string]]::new()
        $RetryAfterSeconds = 0

        foreach ($Response in $ApiResponse.responses) {

            if ($Response.status -eq 200) {

                if ($Response.body.userPurpose) {
                    $Rows += [PSCustomObject]@{
                        UPN     = $UpnById[$Response.id]
                        Purpose = $Response.body.userPurpose
                    }
                }

            } elseif ($Response.status -in 429, 503, 504) {

                $RetryKeys.Add($Response.id)
                $HeaderRetryAfter = 0
                if ($Response.headers.'Retry-After' -and [int]::TryParse($Response.headers.'Retry-After', [ref]$HeaderRetryAfter)) {
                    $RetryAfterSeconds = [Math]::Max($RetryAfterSeconds, $HeaderRetryAfter)
                }

            }
            # Any other status (404, etc.) is a permanent "nothing to report" - dropped, same as before.

        }

        if ($RetryKeys.Count -eq 0) { $PendingKeys = @(); break }

        if ($Attempt -ge $MaxAttempts) {
            Write-Host "Warning: $($RetryKeys.Count) mailbox purpose lookup(s) still failing after $MaxAttempts attempts, skipped: $($RetryKeys -join ', ')" -ForegroundColor Yellow
            $PendingKeys = @()
        } else {
            $Delay = if ($RetryAfterSeconds -gt 0) { $RetryAfterSeconds } else { 2 * $Attempt }
            Write-Host "$($RetryKeys.Count) mailbox purpose lookup(s) hit a transient error, retrying in ${Delay}s (attempt $Attempt of $MaxAttempts)..." -ForegroundColor Yellow
            Start-Sleep -Seconds $Delay
            $PendingKeys = @($RetryKeys)
        }

    }

}

Test-Directory (Split-Path $OutputPath -Parent)
Export-Utf8NoBomCsv -Path $OutputPath -InputObject @($Rows)

$TotalSeconds = ((Get-Date) - $StartTime).TotalSeconds
Write-Host ("Wrote {0} mailbox purpose record(s) to {1} in {2:N0}s" -f $Rows.Count, $OutputPath, $TotalSeconds) -ForegroundColor Green
