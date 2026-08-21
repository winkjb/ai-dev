<#
.SYNOPSIS
    Collector: pulls live firewall policy hit counters (joined with policy config) and VIP
    config from a FortiGate site via REST API - raw and unfiltered, no interpretation. Writes
    data/raw/<Directory>/FirewallPolicies.csv and FirewallVips.csv. Analyst scripts (e.g.
    ../02-analyst/Compare-PolicyAudit-ZeroHits.ps1) read these files rather than calling the
    FortiGate API directly.

.DESCRIPTION
    VIP rows include hit/byte/packet totals rolled up from the policies that reference each VIP
    as a destination - that's a raw join against already-pulled policy data, not a threshold or
    finding, so it stays in the collector.

.EXAMPLE
    .\Collect-FirewallPolicies.ps1 -Directory katz\hq
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Directory,

    [string]$SettingsPath,
    [string]$OutputDir
)

if (-not $SettingsPath) { $SettingsPath = Join-Path $PSScriptRoot "..\data\reference\$Directory\FirewallSettings.txt" }
if (-not $OutputDir)    { $OutputDir    = Join-Path $PSScriptRoot "..\data\raw\$Directory" }

. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-VA-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-FortiGate-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-Formatting-Common.ps1")

$StartTime = Get-Date

$CustomerSettings = Import-Settings -SettingsPath $SettingsPath
$Context = Connect-FortiGate -CustomerSettings $CustomerSettings

Test-Directory $OutputDir

# --- policies ---------------------------------------------------------------

Write-Host "Fetching policy hit counters..." -ForegroundColor Cyan
$PolicyMonitor = Invoke-FGTApi -Context $Context -Path "monitor/firewall/policy"

Write-Host "Fetching policy configuration..." -ForegroundColor Cyan
$PolicyCfg = Invoke-FGTApi -Context $Context -Path "cmdb/firewall/policy"

$PolicyCfgLookup = @{}
if ($PolicyCfg -and $PolicyCfg.results) {
    foreach ($Cfg in $PolicyCfg.results) {
        $PolicyCfgLookup[$Cfg.policyid] = $Cfg
    }
}

$PolicyRows = @(foreach ($Entry in $PolicyMonitor.results) {
    $Cfg = $PolicyCfgLookup[$Entry.policyid]
    [PSCustomObject]@{
        PolicyId       = $Entry.policyid
        Name           = $Cfg.name
        SrcIntf        = ($Cfg.srcintf.name -join ",")
        DstIntf        = ($Cfg.dstintf.name -join ",")
        DstAddr        = ($Cfg.dstaddr.name -join ",")
        Action         = $Cfg.action
        Status         = $Cfg.status
        HitCount       = $Entry.hit_count
        Bytes          = $Entry.bytes
        Packets        = $Entry.packets
        ActiveSessions = $Entry.active_sessions
    }
})
Export-Utf8NoBomCsv -Path (Join-Path $OutputDir "FirewallPolicies.csv") -InputObject @($PolicyRows)

# --- VIPs ---------------------------------------------------------------

Write-Host "Fetching VIP configuration..." -ForegroundColor Cyan
$VipCfg = Invoke-FGTApi -Context $Context -Path "cmdb/firewall/vip"

$VipRows = @()
if ($VipCfg -and $VipCfg.results) {
    $VipRows = @(foreach ($Vip in $VipCfg.results) {
        $RelatedPolicies = $PolicyRows | Where-Object { $_.DstAddr -split "," -contains $Vip.name }

        [PSCustomObject]@{
            VipName         = $Vip.name
            ExtIp           = $Vip.extip
            MappedIp        = ($Vip.mappedip.range -join ",")
            Interface       = $Vip.extintf
            RelatedPolicies = ($RelatedPolicies.PolicyId -join ",")
            TotalHitCount   = ($RelatedPolicies | Measure-Object -Property HitCount -Sum).Sum
            TotalBytes      = ($RelatedPolicies | Measure-Object -Property Bytes -Sum).Sum
            TotalPackets    = ($RelatedPolicies | Measure-Object -Property Packets -Sum).Sum
        }
    })
}
Export-Utf8NoBomCsv -Path (Join-Path $OutputDir "FirewallVips.csv") -InputObject @($VipRows)

$TotalSeconds = ((Get-Date) - $StartTime).TotalSeconds
Write-Host ("Wrote {0} polic(y/ies), {1} VIP(s) to {2} in {3:N0}s" -f $PolicyRows.Count, $VipRows.Count, $OutputDir, $TotalSeconds) -ForegroundColor Green
