<#
.SYNOPSIS
    Collector: pulls the M365 license catalog (per-SKU seat counts) and each user's assigned
    licenses via Graph API - raw and unfiltered, no interpretation. Writes two raw snapshots to
    data/raw/<Directory>/. Analyst scripts (../02-analyst/Compare-LicenseDetail.ps1,
    ../02-analyst/Compare-LicenseSummary.ps1) read these files rather than calling Graph
    directly.

.DESCRIPTION
    Deliberately writes its own EntraLicenses-Usage.csv/EntraLicenses-Assignment.csv rather than
    reusing ../01-collector/Collect-EntraGroupMembers-Admins.ps1's EntraLicenses-Admins.csv/EntraUsers-Admins.csv
    - that collector's license file omits ConsumedUnits/PrepaidUnits (not needed for the
    admin-group audit) and its user file omits DisplayName, both of which the license audits
    need. Matches this workspace's existing precedent of each audit's collector pulling its own
    data even where it overlaps with another collector's pull, rather than one wrapper depending
    on another wrapper having already run first.

    EntraLicenses-Assignment.csv is written pre-expanded (one row per user per assigned SKU) so
    neither Analyst script needs to re-parse a multi-value column.

.EXAMPLE
    .\Collect-EntraLicenses.ps1 -Directory katz
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Directory,

    [string]$SettingsPath,
    [string]$OutputDir
)

if (-not $SettingsPath) { $SettingsPath = Join-Path $PSScriptRoot "..\data\reference\$Directory\M365Settings.txt" }
if (-not $OutputDir)    { $OutputDir    = Join-Path $PSScriptRoot "..\data\raw\$Directory" }

. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-VA-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-M365-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-Formatting-Common.ps1")

$StartTime = Get-Date

$CustomerSettings = Import-Settings -SettingsPath $SettingsPath
$Token = Get-GraphToken -CustomerSettings $CustomerSettings
$Headers = @{ Authorization = "Bearer $Token" }

Test-Directory $OutputDir

# --- license catalog ---------------------------------------------------------------

Write-Host "Fetching license catalog..." -ForegroundColor Cyan
$Uri = "https://graph.microsoft.com/v1.0/subscribedSkus?`$select=skuId,skuPartNumber,consumedUnits,prepaidUnits"
$Licenses = Get-All365Results -Uri $Uri -Headers $Headers

$CatalogRows = foreach ($License in $Licenses) {
    [PSCustomObject]@{
        SkuId                = $License.skuId
        SkuPartNumber        = $License.skuPartNumber
        ConsumedUnits        = $License.consumedUnits
        PrepaidUnitsEnabled  = $License.prepaidUnits.enabled
    }
}
Export-Utf8NoBomCsv -Path (Join-Path $OutputDir "EntraLicenses-Usage.csv") -InputObject @($CatalogRows)

# --- license assignments ---------------------------------------------------------------

Write-Host "Fetching users..." -ForegroundColor Cyan
$Uri = "https://graph.microsoft.com/beta/users?`$select=displayName,userPrincipalName,assignedLicenses,createdDateTime"
$Users = Get-All365Results -Uri $Uri -Headers $Headers

$AssignmentRows = foreach ($User in $Users) {
    foreach ($AssignedLicense in $User.assignedLicenses) {
        [PSCustomObject]@{
            UPN         = $User.userPrincipalName
            DisplayName = $User.displayName
            CreatedDate = $User.createdDateTime
            SkuId       = $AssignedLicense.skuId
        }
    }
}
Export-Utf8NoBomCsv -Path (Join-Path $OutputDir "EntraLicenses-Assignment.csv") -InputObject @($AssignmentRows)

$TotalSeconds = ((Get-Date) - $StartTime).TotalSeconds
Write-Host ("Wrote {0} license(s), {1} assignment(s) to {2} in {3:N0}s" -f $CatalogRows.Count, $AssignmentRows.Count, $OutputDir, $TotalSeconds) -ForegroundColor Green
