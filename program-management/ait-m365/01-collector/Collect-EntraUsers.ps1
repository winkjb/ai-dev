<#
.SYNOPSIS
    Collector: pulls the full Entra ID user list via Graph API - raw and unfiltered, no
    interpretation. Writes one raw snapshot to data/raw/<Directory>/EntraUsers.csv. Analyst
    scripts (../02-analyst/Compare-Users-Temp.ps1, ../02-analyst/Compare-Users-LicensedDisabled.ps1,
    ../02-analyst/Compare-Mailboxes-LicensedShared.ps1) read this file rather than calling Graph
    directly.

.DESCRIPTION
    Deliberately duplicates most of ../01-collector/Collect-EntraGroupMembers-Admins.ps1's own
    users pull rather than reusing its EntraUsers-Admins.csv - that file omits DisplayName (not
    needed for the admin-group audit), which all three of this collector's consumers need
    (temp-user naming, and general readability on every finding row). Same reasoning as
    Collect-EntraLicenses.ps1's documented precedent of an independent pull when field needs
    differ from an existing one.

    Unlike that duplication precedent, this file IS meant to be shared - three new audits all
    need the exact same base fields (DisplayName, UPN, CreatedDate, AccountEnabled, assigned
    licenses, sign-in activity), so one shared pull replaces what would otherwise be three
    near-identical ones.

    The beta users endpoint's signInActivity fields require AuditLog.Read.All, which not every
    tenant's app registration has been granted. If that call fails, falls back to a users pull
    without signInActivity and records SignInActivityAvailable=N on every row, matching
    Collect-EntraGroupMembers-Admins.ps1's convention.

.EXAMPLE
    .\Collect-EntraUsers.ps1 -Directory katz
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Directory,

    [string]$SettingsPath,
    [string]$OutputPath
)

if (-not $SettingsPath) { $SettingsPath = Join-Path $PSScriptRoot "..\data\reference\$Directory\M365Settings.txt" }
if (-not $OutputPath)   { $OutputPath   = Join-Path $PSScriptRoot "..\data\raw\$Directory\EntraUsers.csv" }

. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-VA-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-M365-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-Formatting-Common.ps1")

$StartTime = Get-Date

$CustomerSettings = Import-Settings -SettingsPath $SettingsPath
$Token = Get-GraphToken -CustomerSettings $CustomerSettings
$Headers = @{ Authorization = "Bearer $Token" }

Write-Host "Fetching users..." -ForegroundColor Cyan
$SignInActivityAvailable = $true
try {
    $Uri = "https://graph.microsoft.com/beta/users?`$select=displayName,userPrincipalName,createdDateTime,accountEnabled,assignedLicenses,signInActivity"
    $Users = Get-All365Results -Uri $Uri -Headers $Headers
} catch {
    Write-Host "signInActivity pull failed (likely missing AuditLog.Read.All) - falling back without it." -ForegroundColor Yellow
    $Uri = "https://graph.microsoft.com/beta/users?`$select=displayName,userPrincipalName,createdDateTime,accountEnabled,assignedLicenses"
    $Users = Get-All365Results -Uri $Uri -Headers $Headers
    $SignInActivityAvailable = $false
}

$Rows = foreach ($User in $Users) {
    [PSCustomObject]@{
        DisplayName                      = $User.displayName
        UserPrincipalName                = $User.userPrincipalName
        CreatedDate                      = $User.createdDateTime
        AccountEnabled                   = $User.accountEnabled
        AssignedSkuIds                   = ($User.assignedLicenses | ForEach-Object { $_.skuId }) -join ","
        LastSuccessfulSignInDateTime     = $User.signInActivity.lastSuccessfulSignInDateTime
        LastNonInteractiveSignInDateTime = $User.signInActivity.lastNonInteractiveSignInDateTime
        SignInActivityAvailable          = if ($SignInActivityAvailable) { "Y" } else { "N" }
    }
}

Test-Directory (Split-Path $OutputPath -Parent)
Export-Utf8NoBomCsv -Path $OutputPath -InputObject @($Rows)

$TotalSeconds = ((Get-Date) - $StartTime).TotalSeconds
Write-Host ("Wrote {0} user(s) to {1} in {2:N0}s" -f $Rows.Count, $OutputPath, $TotalSeconds) -ForegroundColor Green
