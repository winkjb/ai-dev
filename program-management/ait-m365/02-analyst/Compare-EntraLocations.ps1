<#
.SYNOPSIS
    Analyst: reformats a customer's collected named locations
    (../01-collector/Collect-EntraLocations.ps1's raw snapshot) into a flat report - one
    row per location with its IP ranges or countries/regions joined into a single readable
    column. Does not call Graph and does not email - that's the collector's and the customer
    wrapper's job, respectively (see ../katz/Invoke-PolicyAudit-Locations.ps1).

.DESCRIPTION
    IsTrusted is only meaningful for IP-based locations - reported as "N/A" for country/region
    locations, matching the original script's output. Which one a location is comes from
    LocationType (the location's real Graph @odata.type, captured by the collector) rather than
    from whether CidrAddresses happens to be non-empty - see the collector's own .DESCRIPTION
    for why that distinction matters.

.EXAMPLE
    .\Compare-EntraLocations.ps1 -Directory katz
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Directory,

    [string]$RawPath,
    [string]$OutputPath
)

if (-not $RawPath)    { $RawPath    = Join-Path $PSScriptRoot "..\data\raw\$Directory\EntraNamedLocations.csv" }
if (-not $OutputPath) { $OutputPath = Join-Path $PSScriptRoot "output\$Directory\Locations-Audit.csv" }

. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-VA-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-Formatting-Common.ps1")

$Now = Get-Date

$Locations = @(Import-Csv -LiteralPath $RawPath -Encoding UTF8)

$Results = foreach ($Location in $Locations) {

    $IsIpLocation = $Location.LocationType -eq "#microsoft.graph.ipNamedLocation"

    [PSCustomObject][ordered]@{
        Date        = $Now.ToString("yyyy-MM-dd")
        DisplayName = $Location.DisplayName
        CreatedDate = $Location.CreatedDate
        IsTrusted   = if ($IsIpLocation) { $Location.IsTrusted } else { "N/A" }
        Locations   = if ($IsIpLocation) { $Location.CidrAddresses } else { $Location.CountriesAndRegions }
    }

}

$Results = @($Results | Sort-Object DisplayName)

Test-Directory (Split-Path $OutputPath -Parent)
Export-Utf8NoBomCsv -Path $OutputPath -InputObject $Results

Write-Host "$($Results.Count) named location(s) audited."
Write-Host "Findings written to $OutputPath"
