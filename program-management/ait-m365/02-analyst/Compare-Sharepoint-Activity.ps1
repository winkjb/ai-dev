<#
.SYNOPSIS
    Analyst: shapes a customer's collected SharePoint usage report
    (../01-collector/Collect-EntraSharepointActivity.ps1's raw snapshot) into a flat report.
    Does not call Graph and does not email - that's the collector's and the customer wrapper's
    job, respectively (see ../katz/Invoke-SiteAuditSharepoint-Activity.ps1).

.DESCRIPTION
    Excludes deleted sites, and system sites whose Root Web Template is "Team Channel" or ends
    in " Search Center" (Teams-channel-backed sites and search-center sites, not real customer
    content), always. Sites listed in data/reference/<Directory>/excluded-sharepoint-sites.csv
    (matched by site Name) are dropped from the findings by default - pass -IncludeExclusions to
    keep them, marked via an Excluded column.

    Reporting-only - no baseline/threshold, just the current usage snapshot per site.

.EXAMPLE
    .\Compare-Sharepoint-Activity.ps1 -Directory katz
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Directory,

    [string]$RawPath,
    [string]$ExclusionsPath,
    [string]$OutputPath,

    [switch]$IncludeExclusions
)

if (-not $RawPath)        { $RawPath        = Join-Path $PSScriptRoot "..\data\raw\$Directory\EntraSharepointActivity.csv" }
if (-not $ExclusionsPath) { $ExclusionsPath = Join-Path $PSScriptRoot "..\data\reference\$Directory\excluded-sharepoint-sites.csv" }
if (-not $OutputPath)     { $OutputPath     = Join-Path $PSScriptRoot "output\$Directory\Sharepoint-Activity.csv" }

. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-VA-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-Formatting-Common.ps1")

$Now = Get-Date

# --- load -----------------------------------------------------------------

$Sites = @(Import-Csv -LiteralPath $RawPath -Encoding UTF8)
$ExclusionRows = if (Test-Path -LiteralPath $ExclusionsPath) { @(Import-Csv -LiteralPath $ExclusionsPath -Encoding UTF8) } else { @() }
$ExcludedNames = @($ExclusionRows | ForEach-Object { $_.Name } | Where-Object { $_ })

# --- filter/shape -------------------------------------------------------------------

$InScope = @($Sites.Where({
    ($_.IsDeleted -ne "True") -and
    ($_.RootWebTemplate -ne "Team Channel") -and
    ($_.RootWebTemplate -notlike "* Search Center")
}))

$ExcludedCount = 0

$Results = foreach ($Site in $InScope) {

    $IsExcluded = $ExcludedNames -contains $Site.Name
    if ($IsExcluded) { $ExcludedCount++ }

    if (-not $IsExcluded -or $IncludeExclusions) {

        $StorageUsedGb = [math]::Round([double]$Site.StorageUsedBytes / 1000000000, 2)
        $StorageMaxGb = [math]::Round([double]$Site.StorageAllocatedBytes / 1000000000, 2)
        $StoragePercentage = if ($StorageMaxGb -gt 0) { [math]::Round(($StorageUsedGb / $StorageMaxGb) * 100) } else { $null }

        $Finding = [ordered]@{
            SiteName          = $Site.Name
            WebUrl            = $Site.WebUrl
            ActiveFileCount   = $Site.ActiveFileCount
            FileCount         = $Site.FileCount
            StorageUsedGb     = $StorageUsedGb
            StorageMaxGb      = $StorageMaxGb
            StoragePercentage = $StoragePercentage
            CreatedDate       = $Site.CreatedDate
            LastActivityDate  = $Site.LastActivityDate
            DaysAgo           = Get-DaysSince -Value $Site.LastActivityDate -Reference $Now
        }
        if ($IncludeExclusions) { $Finding.Excluded = if ($IsExcluded) { "Y" } else { $null } }
        [PSCustomObject]$Finding

    }

}

$Results = @($Results | Sort-Object SiteName)

Test-Directory (Split-Path $OutputPath -Parent)
Export-Utf8NoBomCsv -Path $OutputPath -InputObject $Results

Write-Host "$($InScope.Count) in-scope site(s) audited."
Write-Host "$ExcludedCount site(s) excluded via $(Split-Path $ExclusionsPath -Leaf)."
Write-Host "$($Results.Count) row(s) written to $OutputPath"
