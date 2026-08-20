<#
.SYNOPSIS
    Analyst: compares a customer's collected license assignments
    (../01-collector/Collect-EntraLicenses.ps1's raw snapshot) against the exclusion baseline
    and writes one row per user per non-excluded license. Does not call Graph and does not
    email - that's the collector's and the customer wrapper's job, respectively (see
    ../katz/Invoke-LicenseAudit-Detail.ps1).

.DESCRIPTION
    Licenses listed in data/reference/<Directory>/excluded-licenses.csv (matched by
    SkuPartNumber) are dropped by default - pass -IncludeExclusions to keep them in the output
    instead, marked via an IsExcluded column (only appears in the output at all when
    -IncludeExclusions is used, matching ../02-analyst/Compare-Groups-Temp.ps1's convention).

.EXAMPLE
    .\Compare-LicenseDetail.ps1 -Directory katz
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Directory,

    [string]$CatalogPath,
    [string]$AssignmentsPath,
    [string]$ExclusionsPath,
    [string]$OutputPath,
    [switch]$IncludeExclusions
)

if (-not $CatalogPath)     { $CatalogPath     = Join-Path $PSScriptRoot "..\data\raw\$Directory\EntraLicenses-Usage.csv" }
if (-not $AssignmentsPath) { $AssignmentsPath = Join-Path $PSScriptRoot "..\data\raw\$Directory\EntraLicenses-Assignment.csv" }
if (-not $ExclusionsPath)  { $ExclusionsPath  = Join-Path $PSScriptRoot "..\data\reference\$Directory\excluded-licenses.csv" }
if (-not $OutputPath)      { $OutputPath      = Join-Path $PSScriptRoot "output\$Directory\LicenseAudit-Detail.csv" }

. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-VA-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-M365-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-Formatting-Common.ps1")

$Now = Get-Date

# --- load -----------------------------------------------------------------

$Catalog = @(Import-Csv -LiteralPath $CatalogPath -Encoding UTF8)
$Assignments = @(Import-Csv -LiteralPath $AssignmentsPath -Encoding UTF8)
$ExclusionRows = if (Test-Path -LiteralPath $ExclusionsPath) { @(Import-Csv -LiteralPath $ExclusionsPath -Encoding UTF8) } else { @() }
$ExcludedSkuParts = @($ExclusionRows | ForEach-Object { $_.SkuPartNumber } | Where-Object { $_ })

$AssignmentsBySku = @{}
foreach ($Assignment in $Assignments) { Add-ToIndex -Index $AssignmentsBySku -Key $Assignment.SkuId -Value $Assignment }

# --- audit ------------------------------------------------------------------

$CountLicenses = 0
$CountExclusions = 0

$Results = foreach ($License in $Catalog) {

    $CountLicenses++
    $IsExcluded = $ExcludedSkuParts -contains $License.SkuPartNumber
    if ($IsExcluded) { $CountExclusions++ }

    if (-not $IsExcluded -or $IncludeExclusions) {

        $FriendlyName = Get-FriendlyLicenseName -sku $License.SkuPartNumber

        # Not wrapped in @() - a SKU with no assignments means this lookup returns $null, and
        # `foreach ($x in $null)` is a safe zero-iteration no-op, whereas @($null) would wrap it
        # into a one-element array and emit a spurious blank row.
        $LicensedUsers = $AssignmentsBySku[$License.SkuId]

        foreach ($User in $LicensedUsers) {

            $Finding = [ordered]@{
                Date        = $Now.ToString("yyyy-MM-dd")
                DisplayName = $User.DisplayName
                UPN         = $User.UPN
                UserLicense = $FriendlyName
                CreatedDate = $User.CreatedDate
                DaysAgo     = Get-DaysSince -Value $User.CreatedDate -Reference $Now
            }
            if ($IncludeExclusions) { $Finding.IsExcluded = if ($IsExcluded) {"Y"} else {$null} }
            [PSCustomObject]$Finding

        }

    }

}

$Results = @($Results | Sort-Object DisplayName, UserLicense)

Test-Directory (Split-Path $OutputPath -Parent)
Export-Utf8NoBomCsv -Path $OutputPath -InputObject $Results

Write-Host "$CountLicenses license(s) in catalog."
Write-Host "$CountExclusions license(s) excluded."
Write-Host "$($Results.Count) finding(s) written to $OutputPath"
