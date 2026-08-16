<#
.SYNOPSIS
    Collector: pulls the current membership of a customer's Conditional Access exclusion
    groups (interactive-login block, geo-IP fencing, MFA, modern-auth) via Graph API - raw and
    unfiltered, no interpretation. Writes one raw snapshot to data/raw/<Directory>/. Analyst
    scripts (e.g. ../02-analyst/Compare-CaGroupAudit.ps1) read this file rather than calling
    Graph directly.

.DESCRIPTION
    -GroupNames defaults to the 4 CA exclusion group display names from the original
    katz/Invoke-CaGroupMemberAudit-Default.ps1 script - override per-call if a customer's CA
    groups are named differently.

    A group that can't be found by display name is still written as a single row
    (GroupFound=N, everything else blank) so the Analyst layer can flag "group not found"
    without re-querying Graph. Likewise, a group that IS found but currently has zero members
    still gets a marker row (GroupFound=Y, UPN blank) - an empty PowerShell array is falsy, so
    without this marker "group found, no members" would be indistinguishable from "group not
    found" once written to CSV and read back.

.EXAMPLE
    .\Collect-EntraCaGroupMembers.ps1 -Directory katz
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Directory,

    [string[]]$GroupNames = @(
        "Block Interactive Login Group",
        "Geo-IP Fencing Exclusion Group",
        "MFA Exclusion Group",
        "Modern Authentication Exclusion Group"
    ),

    [string]$SettingsPath,
    [string]$OutputPath
)

if (-not $SettingsPath) { $SettingsPath = Join-Path $PSScriptRoot "..\$Directory\CustomerSettings.txt" }
if (-not $OutputPath)   { $OutputPath   = Join-Path $PSScriptRoot "..\data\raw\$Directory\EntraCaGroupMembers.csv" }

. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-VA-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-M365-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-Formatting-Common.ps1")

$StartTime = Get-Date

$CustomerSettings = Import-Settings -SettingsPath $SettingsPath
$Token = Get-GraphToken -CustomerSettings $CustomerSettings
$Headers = @{ Authorization = "Bearer $Token" }

# --- groups ---------------------------------------------------------------

Write-Host "Fetching group list..." -ForegroundColor Cyan
$Uri = "https://graph.microsoft.com/v1.0/groups?`$select=id,displayName"
$AllGroups = Get-All365Results -Uri $Uri -Headers $Headers

$GroupIdByName = @{}
foreach ($Group in $AllGroups) { $GroupIdByName[$Group.displayName] = $Group.id }

# --- members ---------------------------------------------------------------

$Rows = foreach ($GroupName in $GroupNames) {

    $GroupId = $GroupIdByName[$GroupName]

    if (-not $GroupId) {

        Write-Host "$GroupName not found." -ForegroundColor Yellow
        [PSCustomObject]@{
            GroupName      = $GroupName
            GroupFound     = "N"
            UPN            = $null
            DisplayName    = $null
            CreatedDate    = $null
            AccountEnabled = $null
        }
        continue

    }

    Write-Host "Fetching members of $GroupName..." -ForegroundColor Cyan
    $Uri = "https://graph.microsoft.com/v1.0/groups/$GroupId/members/microsoft.graph.user?`$select=id,displayName,userPrincipalName,createdDateTime,accountEnabled"
    $Members = Get-All365Results -Uri $Uri -Headers $Headers

    if ($Members) {

        foreach ($Member in $Members) {
            [PSCustomObject]@{
                GroupName      = $GroupName
                GroupFound     = "Y"
                UPN            = $Member.userPrincipalName
                DisplayName    = $Member.displayName
                CreatedDate    = $Member.createdDateTime
                AccountEnabled = $Member.accountEnabled
            }
        }

    } else {

        [PSCustomObject]@{
            GroupName      = $GroupName
            GroupFound     = "Y"
            UPN            = $null
            DisplayName    = $null
            CreatedDate    = $null
            AccountEnabled = $null
        }

    }

}

$Rows = @($Rows)

Test-Directory (Split-Path $OutputPath -Parent)
Export-Utf8NoBomCsv -Path $OutputPath -InputObject $Rows

$TotalSeconds = ((Get-Date) - $StartTime).TotalSeconds
Write-Host ("Wrote {0} row(s) across {1} group(s) to {2} in {3:N0}s" -f $Rows.Count, $GroupNames.Count, $OutputPath, $TotalSeconds) -ForegroundColor Green
