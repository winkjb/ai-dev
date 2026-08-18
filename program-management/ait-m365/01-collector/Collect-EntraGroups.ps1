<#
.SYNOPSIS
    Collector: pulls the full Entra ID group list for a customer tenant via Graph API and
    writes it to data/raw/<Directory>/EntraGroups.csv - raw and unfiltered, no interpretation.
    Analyst scripts (e.g. ../02-analyst/Compare-Groups-Temp.ps1) read this file rather than
    calling Graph directly, so any future audit built off Entra groups can reuse this same
    snapshot instead of re-pulling it.

.EXAMPLE
    .\Collect-EntraGroups.ps1 -Directory katz
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Directory,

    [string]$SettingsPath,
    [string]$OutputPath
)

if (-not $SettingsPath) { $SettingsPath = Join-Path $PSScriptRoot "..\data\reference\$Directory\M365Settings.txt" }
if (-not $OutputPath)   { $OutputPath   = Join-Path $PSScriptRoot "..\data\raw\$Directory\EntraGroups.csv" }

. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-VA-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-M365-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-Formatting-Common.ps1")

$StartTime = Get-Date

$CustomerSettings = Import-Settings -SettingsPath $SettingsPath
$Token = Get-GraphToken -CustomerSettings $CustomerSettings
$Headers = @{ Authorization = "Bearer $Token" }

Write-Host "Fetching Entra groups..." -ForegroundColor Cyan
$Uri = "https://graph.microsoft.com/v1.0/groups?`$select=id,displayName,mail,createdDateTime,groupTypes"
$Groups = Get-All365Results -Uri $Uri -Headers $Headers

$Rows = foreach ($Group in $Groups) {
    [PSCustomObject]@{
        Id          = $Group.id
        DisplayName = $Group.displayName
        Mail        = $Group.mail
        CreatedDate = $Group.createdDateTime
        GroupTypes  = $Group.groupTypes -join ","
    }
}

Test-Directory (Split-Path $OutputPath -Parent)
Export-Utf8NoBomCsv -Path $OutputPath -InputObject @($Rows)

$TotalSeconds = ((Get-Date) - $StartTime).TotalSeconds
Write-Host ("Wrote {0} group(s) to {1} in {2:N0}s" -f $Rows.Count, $OutputPath, $TotalSeconds) -ForegroundColor Green
