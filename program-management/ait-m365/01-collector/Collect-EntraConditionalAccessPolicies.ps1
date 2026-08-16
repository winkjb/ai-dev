<#
.SYNOPSIS
    Collector: pulls the tenant's Conditional Access policies, plus the directory users,
    groups, and admin roles needed to resolve the GUIDs those policies reference, via Graph
    API - raw and unfiltered, no interpretation. Writes four raw snapshots to
    data/raw/<Directory>/. Analyst scripts (../02-analyst/Compare-ConditionalAccessPolicyAudit.ps1)
    read these files rather than calling Graph directly.

.DESCRIPTION
    Each policy's include/exclude users/groups/roles conditions are written as raw comma-joined
    GUID lists (or the literal string "All" where Graph returns it) - resolving those GUIDs to
    display names is the Analyst's job, not the collector's.

    Writes its own EntraDirectoryUsers.csv/EntraDirectoryGroups.csv rather than reusing
    ../01-collector/Collect-EntraGroups.ps1's EntraGroups.csv or another collector's user
    snapshot - this audit only needs Id/DisplayName (no mail/createdDate/etc.), and every other
    collector in this project pulls its own data independently rather than depending on one
    wrapper having already run (see ../01-collector/Collect-EntraLicenses.ps1's .DESCRIPTION for
    the one place that pattern was deliberately broken, and why).

.EXAMPLE
    .\Collect-EntraConditionalAccessPolicies.ps1 -Directory katz
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

# --- users ---------------------------------------------------------------

Write-Host "Fetching users..." -ForegroundColor Cyan
$Uri = "https://graph.microsoft.com/v1.0/users?`$select=id,displayName"
$Users = Get-All365Results -Uri $Uri -Headers $Headers

$UserRows = foreach ($User in $Users) {
    [PSCustomObject]@{ Id = $User.id; DisplayName = $User.displayName }
}
Export-Utf8NoBomCsv -Path (Join-Path $OutputDir "EntraDirectoryUsers.csv") -InputObject @($UserRows)

# --- groups ---------------------------------------------------------------

Write-Host "Fetching groups..." -ForegroundColor Cyan
$Uri = "https://graph.microsoft.com/v1.0/groups?`$select=id,displayName"
$Groups = Get-All365Results -Uri $Uri -Headers $Headers

$GroupRows = foreach ($Group in $Groups) {
    [PSCustomObject]@{ Id = $Group.id; DisplayName = $Group.displayName }
}
Export-Utf8NoBomCsv -Path (Join-Path $OutputDir "EntraDirectoryGroups.csv") -InputObject @($GroupRows)

# --- roles ---------------------------------------------------------------

Write-Host "Fetching role definitions..." -ForegroundColor Cyan
$Uri = "https://graph.microsoft.com/beta/roleManagement/directory/roleDefinitions?`$select=id,displayName"
$Roles = Get-All365Results -Uri $Uri -Headers $Headers

$RoleRows = foreach ($Role in $Roles) {
    [PSCustomObject]@{ Id = $Role.id; DisplayName = $Role.displayName }
}
Export-Utf8NoBomCsv -Path (Join-Path $OutputDir "EntraDirectoryRoles.csv") -InputObject @($RoleRows)

# --- policies ---------------------------------------------------------------

Write-Host "Fetching Conditional Access policies..." -ForegroundColor Cyan
$Uri = "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies?`$select=displayName,templateId,state,conditions"
$Policies = Get-All365Results -Uri $Uri -Headers $Headers

$PolicyRows = foreach ($Policy in $Policies) {
    [PSCustomObject]@{
        DisplayName   = $Policy.displayName
        TemplateId    = $Policy.templateId
        State         = $Policy.state
        IncludeUsers  = ($Policy.conditions.users.includeUsers) -join ","
        ExcludeUsers  = ($Policy.conditions.users.excludeUsers) -join ","
        IncludeGroups = ($Policy.conditions.users.includeGroups) -join ","
        ExcludeGroups = ($Policy.conditions.users.excludeGroups) -join ","
        IncludeRoles  = ($Policy.conditions.users.includeRoles) -join ","
        ExcludeRoles  = ($Policy.conditions.users.excludeRoles) -join ","
    }
}
Export-Utf8NoBomCsv -Path (Join-Path $OutputDir "EntraConditionalAccessPolicies.csv") -InputObject @($PolicyRows)

$TotalSeconds = ((Get-Date) - $StartTime).TotalSeconds
Write-Host ("Wrote {0} user(s), {1} group(s), {2} role(s), {3} polic(y/ies) to {4} in {5:N0}s" -f $UserRows.Count, $GroupRows.Count, $RoleRows.Count, $PolicyRows.Count, $OutputDir, $TotalSeconds) -ForegroundColor Green
