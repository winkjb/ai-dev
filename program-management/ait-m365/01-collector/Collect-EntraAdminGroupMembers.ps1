<#
.SYNOPSIS
    Collector: pulls Entra ID directory role assignments, the users holding them, and the
    tenant's license catalog via Graph API - raw and unfiltered, no interpretation. Writes three
    raw snapshots to data/raw/<Directory>/. Analyst scripts (e.g.
    ../02-analyst/Compare-AdminGroupAudit.ps1) read these files rather than calling Graph
    directly.

.DESCRIPTION
    Pulls ALL directory role assignments, not just specific admin roles - an Analyst's
    "overlapping permissions" check needs the full picture of every role a given user holds,
    not just whichever roles it's specifically auditing. Role IDs are resolved to their display
    name at collection time (a reference-data join, not interpretation) so raw rows are
    human-readable and Analyst scripts can match by role name directly.

    The beta users endpoint's signInActivity fields require AuditLog.Read.All, which not every
    tenant's app registration has been granted. If that call fails, falls back to a users pull
    without signInActivity and records SignInActivityAvailable=N on every row, so an Analyst can
    tell "no permission to check" apart from "no logon on record."

.EXAMPLE
    .\Collect-EntraAdminGroupMembers.ps1 -Directory katz
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Directory,

    [string]$SettingsPath,
    [string]$OutputDir
)

if (-not $SettingsPath) { $SettingsPath = Join-Path $PSScriptRoot "..\$Directory\CustomerSettings.txt" }
if (-not $OutputDir)    { $OutputDir    = Join-Path $PSScriptRoot "..\data\raw\$Directory" }

. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-VA-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-M365-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-Formatting-Common.ps1")

$StartTime = Get-Date

$CustomerSettings = Import-Settings -SettingsPath $SettingsPath
$Token = Get-GraphToken -CustomerSettings $CustomerSettings
$Headers = @{ Authorization = "Bearer $Token" }

Test-Directory $OutputDir

# --- licenses ---------------------------------------------------------------

Write-Host "Fetching license catalog..." -ForegroundColor Cyan
$Uri = "https://graph.microsoft.com/v1.0/subscribedSkus?`$select=skuId,skuPartNumber"
$Licenses = Get-All365Results -Uri $Uri -Headers $Headers

$LicenseRows = foreach ($License in $Licenses) {
    [PSCustomObject]@{
        SkuId         = $License.skuId
        SkuPartNumber = $License.skuPartNumber
    }
}
Export-Utf8NoBomCsv -Path (Join-Path $OutputDir "EntraLicenses.csv") -InputObject @($LicenseRows)

# --- role assignments ---------------------------------------------------------------

Write-Host "Fetching role definitions..." -ForegroundColor Cyan
$Uri = "https://graph.microsoft.com/beta/roleManagement/directory/roleDefinitions?`$select=id,displayName"
$Roles = Get-All365Results -Uri $Uri -Headers $Headers
$RoleNameById = @{}
foreach ($Role in $Roles) { $RoleNameById[$Role.id] = $Role.displayName }

Write-Host "Fetching role assignments..." -ForegroundColor Cyan
$Uri = "https://graph.microsoft.com/beta/roleManagement/directory/roleAssignments?`$expand=principal"
$Assignments = Get-All365Results -Uri $Uri -Headers $Headers

$AssignmentRows = foreach ($Assignment in $Assignments) {
    [PSCustomObject]@{
        RoleName    = $RoleNameById[$Assignment.roleDefinitionId]
        UPN         = $Assignment.principal.userPrincipalName
        DisplayName = $Assignment.principal.displayName
    }
}
Export-Utf8NoBomCsv -Path (Join-Path $OutputDir "EntraRoleAssignments.csv") -InputObject @($AssignmentRows)

# --- users ---------------------------------------------------------------

Write-Host "Fetching users..." -ForegroundColor Cyan
$SignInActivityAvailable = $true
try {
    $Uri = "https://graph.microsoft.com/beta/users?`$select=UserPrincipalName,createdDateTime,accountEnabled,assignedLicenses,signInActivity"
    $Users = Get-All365Results -Uri $Uri -Headers $Headers
} catch {
    Write-Host "signInActivity pull failed (likely missing AuditLog.Read.All) - falling back without it." -ForegroundColor Yellow
    $Uri = "https://graph.microsoft.com/beta/users?`$select=UserPrincipalName,createdDateTime,accountEnabled,assignedLicenses"
    $Users = Get-All365Results -Uri $Uri -Headers $Headers
    $SignInActivityAvailable = $false
}

$UserRows = foreach ($User in $Users) {
    [PSCustomObject]@{
        UserPrincipalName                = $User.userPrincipalName
        CreatedDate                      = $User.createdDateTime
        AccountEnabled                   = $User.accountEnabled
        AssignedSkuIds                   = ($User.assignedLicenses | ForEach-Object { $_.skuId }) -join ","
        LastSuccessfulSignInDateTime     = $User.signInActivity.lastSuccessfulSignInDateTime
        LastNonInteractiveSignInDateTime = $User.signInActivity.lastNonInteractiveSignInDateTime
        SignInActivityAvailable          = if ($SignInActivityAvailable) { "Y" } else { "N" }
    }
}
Export-Utf8NoBomCsv -Path (Join-Path $OutputDir "EntraUsers.csv") -InputObject @($UserRows)

$TotalSeconds = ((Get-Date) - $StartTime).TotalSeconds
Write-Host ("Wrote {0} license(s), {1} role assignment(s), {2} user(s) to {3} in {4:N0}s" -f $LicenseRows.Count, $AssignmentRows.Count, $UserRows.Count, $OutputDir, $TotalSeconds) -ForegroundColor Green
