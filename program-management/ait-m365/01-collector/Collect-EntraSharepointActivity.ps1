<#
.SYNOPSIS
    Collector: pulls the SharePoint site usage report via Graph API, joined against site
    metadata and Team-backed-group membership - raw and unfiltered, no interpretation. Writes
    one raw snapshot to data/raw/<Directory>/EntraSharepointActivity.csv. Analyst scripts
    (../02-analyst/Compare-Sharepoint-Activity.ps1, ../02-analyst/Compare-Sharepoint-Disable.ps1)
    read this file rather than calling Graph directly.

.DESCRIPTION
    A usage-report row is only written if a matching /sites metadata entry exists for it (same
    behavior as the original scripts - the usage report's "Site Id" is joined against
    /sites?$select=...&$select=Id via the second comma-delimited segment of the metadata
    endpoint's compound id, e.g. "hostname,siteCollectionId,webId" - the usage report only ever
    returns the siteCollectionId segment).

    IsTeamBacked resolves whether a SharePoint site's display name matches a group with
    ResourceProvisioningOptions set (i.e. the site is a Microsoft Team's backing SharePoint
    site) - a reference-data join, not interpretation, same as this workspace's role-name/GUID
    resolution precedent elsewhere. ../02-analyst/Compare-Sharepoint-Disable.ps1 uses it to
    avoid double-flagging a site that ../02-analyst/Compare-Teams-Disable.ps1 already covers.

    -ReportingDays selects the Graph report's aggregation window (7/30/90/180 are the only
    values Graph accepts) - defaults to 180, matching the original production wrapper's real
    value.

.EXAMPLE
    .\Collect-EntraSharepointActivity.ps1 -Directory katz
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Directory,

    [ValidateSet(7, 30, 90, 180)]
    [int]$ReportingDays = 180,

    [string]$SettingsPath,
    [string]$OutputPath
)

if (-not $SettingsPath) { $SettingsPath = Join-Path $PSScriptRoot "..\data\reference\$Directory\M365Settings.txt" }
if (-not $OutputPath)   { $OutputPath   = Join-Path $PSScriptRoot "..\data\raw\$Directory\EntraSharepointActivity.csv" }

. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-VA-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-M365-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-Formatting-Common.ps1")

$StartTime = Get-Date

$CustomerSettings = Import-Settings -SettingsPath $SettingsPath
$Token = Get-GraphToken -CustomerSettings $CustomerSettings
$Headers = @{ Authorization = "Bearer $Token" }

# --- site metadata ---------------------------------------------------------------

Write-Host "Fetching sites..." -ForegroundColor Cyan
$Uri = "https://graph.microsoft.com/v1.0/sites?`$select=Name,WebUrl,Id,CreatedDateTime,isPersonalSite"
$AllSites = Get-All365Results -Uri $Uri -Headers $Headers

$SiteByCollectionId = @{}
foreach ($Site in $AllSites) {
    if ($Site.isPersonalSite) { continue }
    $CollectionId = ($Site.id -split ',')[1]
    if ($CollectionId) { $SiteByCollectionId[$CollectionId] = $Site }
}

# --- Team-backed groups ---------------------------------------------------------------

Write-Host "Fetching groups (for Team-backed site resolution)..." -ForegroundColor Cyan
$Uri = "https://graph.microsoft.com/v1.0/groups?`$select=DisplayName,ResourceProvisioningOptions"
$Groups = Get-All365Results -Uri $Uri -Headers $Headers
$TeamGroupNames = @{}
foreach ($Group in $Groups) {
    if ($Group.resourceProvisioningOptions) { $TeamGroupNames[$Group.displayName] = $true }
}

# --- usage report ---------------------------------------------------------------

Write-Host "Fetching SharePoint usage report (D$ReportingDays)..." -ForegroundColor Cyan
$Uri = "https://graph.microsoft.com/v1.0/reports/getSharePointSiteUsageDetail(period='D$ReportingDays')"
$UsageRows = Invoke-RestMethod -Uri $Uri -Headers $Headers | ConvertFrom-Csv -Delimiter ','

$Rows = foreach ($Usage in $UsageRows) {

    $SiteInfo = $SiteByCollectionId[$Usage.'Site Id']
    if (-not $SiteInfo) { continue }

    [PSCustomObject]@{
        SiteId                = $Usage.'Site Id'
        Name                  = $SiteInfo.name
        WebUrl                = $SiteInfo.webUrl
        CreatedDate           = $SiteInfo.createdDateTime
        RootWebTemplate       = $Usage.'Root Web Template'
        IsDeleted             = $Usage.'Is Deleted'
        IsTeamBacked          = if ($SiteInfo.name -and $TeamGroupNames.ContainsKey($SiteInfo.name)) { "Y" } else { "N" }
        ActiveFileCount       = $Usage.'Active File Count'
        FileCount             = $Usage.'File Count'
        StorageUsedBytes      = $Usage.'Storage Used (Byte)'
        StorageAllocatedBytes = $Usage.'Storage Allocated (Byte)'
        LastActivityDate      = $Usage.'Last Activity Date'
    }

}

Test-Directory (Split-Path $OutputPath -Parent)
Export-Utf8NoBomCsv -Path $OutputPath -InputObject @($Rows)

$TotalSeconds = ((Get-Date) - $StartTime).TotalSeconds
Write-Host ("Wrote {0} site(s) to {1} in {2:N0}s" -f $Rows.Count, $OutputPath, $TotalSeconds) -ForegroundColor Green
