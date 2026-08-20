<#
.SYNOPSIS
    Analyst: reformats a customer's collected Conditional Access policies
    (../01-collector/Collect-EntraPolicies-CA.ps1's raw snapshots) into a flat
    report - one row per policy with its included/excluded users, groups, and roles resolved
    from GUIDs to display names. Does not call Graph and does not email - that's the collector's
    and the customer wrapper's job, respectively (see
    ../katz/Invoke-PolicyAudit-CA.ps1).

.DESCRIPTION
    A policy counts as a "Microsoft template policy" when it has a TemplateId and its State is
    "disabled" - matches the original katz/Invoke-PolicyAudit-CA-Default.ps1
    script's definition (Microsoft ships several built-in template policies disabled by
    default, which otherwise clutter a from-scratch tenant's policy list).

    -ExcludeMsPolicies defaults to $true - matches the original katz/Invoke-PolicyAudit-CA-Default.ps1
    script's real production default, which dropped these entirely rather than reporting them.
    Pass -ExcludeMsPolicies:$false to keep them in the output instead, marked via an
    IsMsTemplatePolicy column (only appears in the output at all when at least one is kept,
    matching ../02-analyst/Compare-Groups-Temp.ps1's IsExcluded convention).

.EXAMPLE
    .\Compare-Policies-CA.ps1 -Directory katz
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Directory,

    [string]$UsersPath,
    [string]$GroupsPath,
    [string]$RolesPath,
    [string]$PoliciesPath,
    [string]$OutputPath,

    [switch]$ExcludeMsPolicies = $true
)

if (-not $UsersPath)    { $UsersPath    = Join-Path $PSScriptRoot "..\data\raw\$Directory\EntraUsers-CA.csv" }
if (-not $GroupsPath)   { $GroupsPath   = Join-Path $PSScriptRoot "..\data\raw\$Directory\EntraGroups-CA.csv" }
if (-not $RolesPath)    { $RolesPath    = Join-Path $PSScriptRoot "..\data\raw\$Directory\EntraRoles-CA.csv" }
if (-not $PoliciesPath) { $PoliciesPath = Join-Path $PSScriptRoot "..\data\raw\$Directory\EntraPolicies-CA.csv" }
if (-not $OutputPath)   { $OutputPath   = Join-Path $PSScriptRoot "output\$Directory\PolicyAudit-CA.csv" }

. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-VA-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-Formatting-Common.ps1")

$Now = Get-Date

# --- load -----------------------------------------------------------------

$Users = @(Import-Csv -LiteralPath $UsersPath -Encoding UTF8)
$Groups = @(Import-Csv -LiteralPath $GroupsPath -Encoding UTF8)
$Roles = @(Import-Csv -LiteralPath $RolesPath -Encoding UTF8)
$Policies = @(Import-Csv -LiteralPath $PoliciesPath -Encoding UTF8)

# Users and groups are merged into one lookup - a policy's includeUsers/excludeUsers list can
# only contain user GUIDs and includeGroups/excludeGroups only group GUIDs, so there's no
# collision risk, and it matches the original script's own single merged hashtable.
$PrincipalNameById = @{}
foreach ($User in $Users) { $PrincipalNameById[$User.Id] = $User.DisplayName }
foreach ($Group in $Groups) { $PrincipalNameById[$Group.Id] = $Group.DisplayName }

$RoleNameById = @{}
foreach ($Role in $Roles) { $RoleNameById[$Role.Id] = $Role.DisplayName }

function Resolve-PrincipalNames {
    param([string]$CsvValue, [hashtable]$NameById)

    if (-not $CsvValue) { return $null }
    if ($CsvValue -eq "All") { return "All" }

    $Ids = $CsvValue -split ","
    return (($Ids | ForEach-Object { $NameById[$_] } | Sort-Object) -join ", ")
}

# --- audit ------------------------------------------------------------------

$CountPolicies = 0
$CountExclusions = 0

$Results = foreach ($Policy in $Policies) {

    $CountPolicies++

    $IsMsTemplatePolicy = [bool]($Policy.TemplateId -and $Policy.State -eq "disabled")
    if ($IsMsTemplatePolicy) { $CountExclusions++ }

    if ($IsMsTemplatePolicy -and $ExcludeMsPolicies) { continue }

    $Finding = [ordered]@{
        Date           = $Now.ToString("yyyy-MM-dd")
        DisplayName    = $Policy.DisplayName
        State          = $Policy.State
        IncludedUsers  = Resolve-PrincipalNames -CsvValue $Policy.IncludeUsers -NameById $PrincipalNameById
        ExcludedUsers  = Resolve-PrincipalNames -CsvValue $Policy.ExcludeUsers -NameById $PrincipalNameById
        IncludedRoles  = Resolve-PrincipalNames -CsvValue $Policy.IncludeRoles -NameById $RoleNameById
        ExcludedRoles  = Resolve-PrincipalNames -CsvValue $Policy.ExcludeRoles -NameById $RoleNameById
        IncludedGroups = Resolve-PrincipalNames -CsvValue $Policy.IncludeGroups -NameById $PrincipalNameById
        ExcludedGroups = Resolve-PrincipalNames -CsvValue $Policy.ExcludeGroups -NameById $PrincipalNameById
    }
    if (-not $ExcludeMsPolicies) { $Finding.IsMsTemplatePolicy = if ($IsMsTemplatePolicy) { "Y" } else { $null } }
    [PSCustomObject]$Finding

}

$Results = @($Results | Sort-Object DisplayName)

Test-Directory (Split-Path $OutputPath -Parent)
Export-Utf8NoBomCsv -Path $OutputPath -InputObject $Results

Write-Host "$CountPolicies polic(y/ies) audited."
Write-Host "$CountExclusions Microsoft template polic(y/ies) identified."
Write-Host "$($Results.Count) finding(s) written to $OutputPath"
