<#
.SYNOPSIS
    Collector: pulls the tenant's Conditional Access named locations via Graph API - raw and
    unfiltered, no interpretation. Writes one raw snapshot to data/raw/<Directory>/. Analyst
    scripts (../02-analyst/Compare-NamedLocationsAudit.ps1) read this file rather than calling
    Graph directly.

.DESCRIPTION
    Captures the object's real @odata.type (ipNamedLocation vs. countryNamedLocation) as
    LocationType rather than inferring the type from whether ipRanges has entries, the way the
    original katz/Invoke-PolicyAuditNamedLocations-Default.ps1 script did - an IP-based location
    configured with zero ranges is still an IP location, and PowerShell's empty-array-is-falsy
    behavior would silently misread it as a country-based one instead (the same class of bug
    found and fixed in program-management/ait-networking's FortiGate WAN-redundancy work).

.EXAMPLE
    .\Collect-EntraNamedLocations.ps1 -Directory katz
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Directory,

    [string]$SettingsPath,
    [string]$OutputPath
)

if (-not $SettingsPath) { $SettingsPath = Join-Path $PSScriptRoot "..\$Directory\CustomerSettings.txt" }
if (-not $OutputPath)   { $OutputPath   = Join-Path $PSScriptRoot "..\data\raw\$Directory\EntraNamedLocations.csv" }

. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-VA-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-M365-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-Formatting-Common.ps1")

$StartTime = Get-Date

$CustomerSettings = Import-Settings -SettingsPath $SettingsPath
$Token = Get-GraphToken -CustomerSettings $CustomerSettings
$Headers = @{ Authorization = "Bearer $Token" }

Write-Host "Fetching named locations..." -ForegroundColor Cyan
$Uri = "https://graph.microsoft.com/v1.0/identity/conditionalAccess/namedLocations"
$Locations = Get-All365Results -Uri $Uri -Headers $Headers

$Rows = foreach ($Location in $Locations) {
    [PSCustomObject]@{
        DisplayName         = $Location.displayName
        LocationType        = $Location.'@odata.type'
        CreatedDate         = $Location.createdDateTime
        IsTrusted           = $Location.isTrusted
        CidrAddresses       = ($Location.ipRanges.cidrAddress) -join ","
        CountriesAndRegions = ($Location.countriesAndRegions) -join ","
    }
}

Test-Directory (Split-Path $OutputPath -Parent)
Export-Utf8NoBomCsv -Path $OutputPath -InputObject @($Rows)

$TotalSeconds = ((Get-Date) - $StartTime).TotalSeconds
Write-Host ("Wrote {0} named location(s) to {1} in {2:N0}s" -f $Rows.Count, $OutputPath, $TotalSeconds) -ForegroundColor Green
