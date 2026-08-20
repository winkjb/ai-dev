<#
.SYNOPSIS
    Analyst: shapes a customer's collected OneDrive usage report
    (../01-collector/Collect-EntraOneDriveActivity.ps1's raw snapshot) into a flat report. Does
    not call Graph and does not email - that's the collector's and the customer wrapper's job,
    respectively (see ../katz/Invoke-SiteAuditOneDrive-Activity.ps1).

.DESCRIPTION
    Excludes deleted accounts always, and accounts listed in
    data/reference/<Directory>/excluded-onedrive-accounts.csv (matched by owner UPN) by default -
    pass -IncludeExclusions to keep them, marked via an Excluded column (only appears in the
    output at all when -IncludeExclusions is used, matching
    ../02-analyst/Compare-Groups-Temp.ps1's IsExcluded convention).

    Reporting-only - no baseline/threshold, just the current usage snapshot per account.

.EXAMPLE
    .\Compare-OneDrive-Activity.ps1 -Directory katz
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

if (-not $RawPath)        { $RawPath        = Join-Path $PSScriptRoot "..\data\raw\$Directory\EntraOneDriveActivity.csv" }
if (-not $ExclusionsPath) { $ExclusionsPath = Join-Path $PSScriptRoot "..\data\reference\$Directory\excluded-onedrive-accounts.csv" }
if (-not $OutputPath)     { $OutputPath     = Join-Path $PSScriptRoot "output\$Directory\OneDrive-Activity.csv" }

. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-VA-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-Formatting-Common.ps1")

$Now = Get-Date

# --- load -----------------------------------------------------------------

$Sites = @(Import-Csv -LiteralPath $RawPath -Encoding UTF8)
$ExclusionRows = if (Test-Path -LiteralPath $ExclusionsPath) { @(Import-Csv -LiteralPath $ExclusionsPath -Encoding UTF8) } else { @() }
$ExcludedUpns = @($ExclusionRows | ForEach-Object { $_.UPN } | Where-Object { $_ })

# --- filter/shape -------------------------------------------------------------------

$Active = @($Sites.Where({ $_.IsDeleted -ne "True" }))

$ExcludedCount = 0

$Results = foreach ($Site in $Active) {

    $IsExcluded = $ExcludedUpns -contains $Site.OwnerPrincipalName
    if ($IsExcluded) { $ExcludedCount++ }

    if (-not $IsExcluded -or $IncludeExclusions) {

        $StorageUsedGb = [math]::Round([double]$Site.StorageUsedBytes / 1000000000, 2)
        $StorageMaxGb = [math]::Round([double]$Site.StorageAllocatedBytes / 1000000000, 2)
        $StoragePercentage = if ($StorageMaxGb -gt 0) { [math]::Round(($StorageUsedGb / $StorageMaxGb) * 100) } else { $null }

        $Finding = [ordered]@{
            Date              = $Now.ToString("yyyy-MM-dd")
            DisplayName       = $Site.OwnerDisplayName
            UPN               = $Site.OwnerPrincipalName
            ActiveFileCount   = $Site.ActiveFileCount
            FileCount         = $Site.FileCount
            StorageUsedGb     = $StorageUsedGb
            StorageMaxGb      = $StorageMaxGb
            StoragePercentage = $StoragePercentage
            LastActivityDate  = $Site.LastActivityDate
            DaysAgo           = Get-DaysSince -Value $Site.LastActivityDate -Reference $Now
        }
        if ($IncludeExclusions) { $Finding.Excluded = if ($IsExcluded) { "Y" } else { $null } }
        [PSCustomObject]$Finding

    }

}

$Results = @($Results | Sort-Object DisplayName)

Test-Directory (Split-Path $OutputPath -Parent)
Export-Utf8NoBomCsv -Path $OutputPath -InputObject $Results

Write-Host "$($Active.Count) enabled account(s) audited."
Write-Host "$ExcludedCount account(s) excluded via $(Split-Path $ExclusionsPath -Leaf)."
Write-Host "$($Results.Count) row(s) written to $OutputPath"
