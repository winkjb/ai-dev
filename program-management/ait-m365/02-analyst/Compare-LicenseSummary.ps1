<#
.SYNOPSIS
    Analyst: compares a customer's collected license catalog
    (../01-collector/Collect-EntraLicenses.ps1's raw snapshot) against the exclusion baseline
    and writes one row per non-excluded license summarizing seat usage. Does not call Graph and
    does not email - that's the collector's and the customer wrapper's job, respectively (see
    ../katz/Invoke-LicenseAudit-Summary.ps1).

.DESCRIPTION
    Licenses listed in data/reference/<Directory>/excluded-licenses.csv (matched by
    SkuPartNumber) are dropped by default - pass -IncludeExclusions to keep them in the output
    instead, marked via an IsExcluded column (only appears in the output at all when
    -IncludeExclusions is used, matching ../02-analyst/Compare-Groups-Temp.ps1's convention).

    PercentageUsed keeps the original script's rounding order (round the consumed/max ratio to
    2 decimal places, then multiply by 100) for continuity with its historical numbers.

.EXAMPLE
    .\Compare-LicenseSummary.ps1 -Directory katz
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Directory,

    [string]$CatalogPath,
    [string]$ExclusionsPath,
    [string]$OutputPath,
    [switch]$IncludeExclusions
)

if (-not $CatalogPath)    { $CatalogPath    = Join-Path $PSScriptRoot "..\data\raw\$Directory\EntraLicenses-Usage.csv" }
if (-not $ExclusionsPath) { $ExclusionsPath = Join-Path $PSScriptRoot "..\data\reference\$Directory\excluded-licenses.csv" }
if (-not $OutputPath)     { $OutputPath     = Join-Path $PSScriptRoot "output\$Directory\LicenseAudit-Summary.csv" }

. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-VA-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-M365-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-Formatting-Common.ps1")

# --- load -----------------------------------------------------------------

$Catalog = @(Import-Csv -LiteralPath $CatalogPath -Encoding UTF8)
$ExclusionRows = if (Test-Path -LiteralPath $ExclusionsPath) { @(Import-Csv -LiteralPath $ExclusionsPath -Encoding UTF8) } else { @() }
$ExcludedSkuParts = @($ExclusionRows | ForEach-Object { $_.SkuPartNumber } | Where-Object { $_ })

# --- audit ------------------------------------------------------------------

$CountExclusions = 0

$Results = foreach ($License in $Catalog) {

    $IsExcluded = $ExcludedSkuParts -contains $License.SkuPartNumber
    if ($IsExcluded) { $CountExclusions++ }

    if (-not $IsExcluded -or $IncludeExclusions) {

        $ConsumedLicenses = [int]$License.ConsumedUnits
        $MaxLicenses = [int]$License.PrepaidUnitsEnabled
        $UnusedLicenses = $MaxLicenses - $ConsumedLicenses
        $PercentageUsed = if ($MaxLicenses -eq 0) { 0 } else { [math]::Round($ConsumedLicenses / $MaxLicenses, 2) * 100 }

        $Finding = [ordered]@{
            UserLicense      = Get-FriendlyLicenseName -sku $License.SkuPartNumber
            ConsumedLicenses = $ConsumedLicenses
            MaxLicenses      = $MaxLicenses
            UnusedLicenses   = $UnusedLicenses
            PercentageUsed   = $PercentageUsed
        }
        if ($IncludeExclusions) { $Finding.IsExcluded = if ($IsExcluded) {"Y"} else {$null} }
        [PSCustomObject]$Finding

    }

}

$Results = @($Results | Sort-Object UserLicense)

Test-Directory (Split-Path $OutputPath -Parent)
Export-Utf8NoBomCsv -Path $OutputPath -InputObject $Results

Write-Host "$($Catalog.Count) license(s) in catalog."
Write-Host "$CountExclusions license(s) excluded."
Write-Host "$($Results.Count) finding(s) written to $OutputPath"
