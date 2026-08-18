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
    written - a user with no mailbox at all (no 200 response, or an empty userPurpose) has
    nothing meaningful to report. Output is keyed by UPN, not the Graph object id, so it joins
    directly against every other raw snapshot in this workspace without a separate id lookup.

.EXAMPLE
    .\Collect-EntraMailboxPurpose.ps1 -Directory katz
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Directory,

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

Write-Host "Fetching users..." -ForegroundColor Cyan
$Uri = "https://graph.microsoft.com/v1.0/users?`$select=id,userPrincipalName"
$Users = Get-All365Results -Uri $Uri -Headers $Headers
$UpnById = @{}
foreach ($User in $Users) { $UpnById[$User.id] = $User.userPrincipalName }

Write-Host "Fetching mailbox purpose for $($Users.Count) user(s)..." -ForegroundColor Cyan
$Rows = @()

for ($i = 0; $i -lt $Users.Count; $i += $BatchSize) {

    $UserSlice = $Users[$i..([math]::Min($i + $BatchSize - 1, $Users.Count - 1))]

    $Requests = foreach ($User in $UserSlice) {
        @{
            id     = $User.id
            method = "GET"
            url    = "/users/$($User.id)/mailboxSettings?`$select=userPurpose"
        }
    }

    $Body = @{ requests = @($Requests) } | ConvertTo-Json -Depth 5
    $ApiResponse = Invoke-RestMethod -Method Post -Uri "https://graph.microsoft.com/v1.0/`$batch" -Headers $Headers -Body $Body -ContentType "application/json"

    foreach ($Response in $ApiResponse.responses) {

        if ($Response.status -eq 200 -and $Response.body.userPurpose) {

            $Rows += [PSCustomObject]@{
                UPN     = $UpnById[$Response.id]
                Purpose = $Response.body.userPurpose
            }

        }

    }

}

Test-Directory (Split-Path $OutputPath -Parent)
Export-Utf8NoBomCsv -Path $OutputPath -InputObject @($Rows)

$TotalSeconds = ((Get-Date) - $StartTime).TotalSeconds
Write-Host ("Wrote {0} mailbox purpose record(s) to {1} in {2:N0}s" -f $Rows.Count, $OutputPath, $TotalSeconds) -ForegroundColor Green
