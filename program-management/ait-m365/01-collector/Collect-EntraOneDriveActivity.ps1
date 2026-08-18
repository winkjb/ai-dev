<#
.SYNOPSIS
    Collector: pulls the OneDrive usage report via Graph API - raw and unfiltered, no
    interpretation. Writes one raw snapshot to data/raw/<Directory>/EntraOneDriveActivity.csv.
    Analyst scripts (../02-analyst/Compare-OneDrive-Activity.ps1) read this file rather than
    calling Graph directly.

.DESCRIPTION
    -ReportingDays selects the Graph report's aggregation window (7/30/90/180 are the only
    values Graph accepts) - defaults to 180, matching the original production wrapper's real
    value. A genuine collection-time choice, not something an Analyst can defer - Graph
    pre-aggregates these metrics per period, they aren't raw daily rows.

.EXAMPLE
    .\Collect-EntraOneDriveActivity.ps1 -Directory katz
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
if (-not $OutputPath)   { $OutputPath   = Join-Path $PSScriptRoot "..\data\raw\$Directory\EntraOneDriveActivity.csv" }

. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-VA-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-M365-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-Formatting-Common.ps1")

$StartTime = Get-Date

$CustomerSettings = Import-Settings -SettingsPath $SettingsPath
$Token = Get-GraphToken -CustomerSettings $CustomerSettings
$Headers = @{ Authorization = "Bearer $Token" }

Write-Host "Fetching OneDrive usage report (D$ReportingDays)..." -ForegroundColor Cyan
$Uri = "https://graph.microsoft.com/v1.0/reports/getOneDriveUsageAccountDetail(period='D$ReportingDays')"
$Sites = Invoke-RestMethod -Uri $Uri -Headers $Headers | ConvertFrom-Csv -Delimiter ','

$Rows = foreach ($Site in $Sites) {
    [PSCustomObject]@{
        OwnerPrincipalName    = $Site.'Owner Principal Name'
        OwnerDisplayName      = $Site.'Owner Display Name'
        IsDeleted             = $Site.'Is Deleted'
        ActiveFileCount       = $Site.'Active File Count'
        FileCount             = $Site.'File Count'
        StorageUsedBytes      = $Site.'Storage Used (Byte)'
        StorageAllocatedBytes = $Site.'Storage Allocated (Byte)'
        LastActivityDate      = $Site.'Last Activity Date'
    }
}

Test-Directory (Split-Path $OutputPath -Parent)
Export-Utf8NoBomCsv -Path $OutputPath -InputObject @($Rows)

$TotalSeconds = ((Get-Date) - $StartTime).TotalSeconds
Write-Host ("Wrote {0} account(s) to {1} in {2:N0}s" -f $Rows.Count, $OutputPath, $TotalSeconds) -ForegroundColor Green
