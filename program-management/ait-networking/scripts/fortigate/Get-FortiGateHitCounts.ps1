<#
.SYNOPSIS
    Pulls firewall policy and VIP information + hit counts from a FortiGate via REST API.

.DESCRIPTION
    Queries the FortiGate monitor API for live policy hit counters, joins them with
    policy config (name/src/dst/action), and pulls VIP config. Outputs to console
    and optionally to CSV.

.NOTES
    Requires a FortiGate REST API admin with an API key (Bearer token).
    Tested against FortiOS 6.x/7.x REST API v2.
    -FortiGate and -ApiKey can be passed as parameters, loaded from a
    -ConfigFile, or left blank to be prompted for interactively at runtime
    (API key input is masked when prompted).

.EXAMPLE
    # Fully interactive - prompts for FortiGate address and API key
    .\Get-FortiGateHitCounts.ps1 -ShowZeroHitOnly -ExportCsv

.EXAMPLE
    .\Get-FortiGateHitCounts.ps1 -FortiGate <fortigate-ip-or-host>:8443 -ApiKey "yourkeyhere" -Vdom root -ExportCsv

.EXAMPLE
    # Console output limited to zero-hit policies/VIPs, plus a dedicated CSV of just those
    .\Get-FortiGateHitCounts.ps1 -FortiGate <fortigate-ip-or-host>:8443 -ApiKey "yourkeyhere" -Vdom test -ShowZeroHitOnly -ExportCsv

.EXAMPLE
    # Credentials pulled from a legacy plaintext config file (Key=Value: FortiGate, ApiKey, Vdom)
    .\Get-FortiGateHitCounts.ps1 -ConfigFile ".\fortigate.cfg" -ShowZeroHitOnly -ExportCsv

.EXAMPLE
    # Preferred: credentials pulled from an encrypted CustomerSettings file (see
    # scripts/VA-Functions-Common.ps1 for the decrypt side; the file itself is
    # produced by the existing VA settings-encryption process, not by this repo)
    .\Get-FortiGateHitCounts.ps1 -CustomerSettingsPath "..\..\data\reference\customers\aqs\hq\CustomerSettings.txt" -ExcludeDisabled -ExportCsv

.EXAMPLE
    # Exclude administratively disabled policies from the zero-hit report entirely
    .\Get-FortiGateHitCounts.ps1 -ConfigFile ".\fortigate.cfg" -ExcludeDisabled -ExportCsv
#>

[CmdletBinding()]
param(
    [string]$FortiGate,

    [string]$ApiKey,

    [string]$Vdom,

    [switch]$ExportCsv,

    [switch]$ShowZeroHitOnly,

    [switch]$ExcludeDisabled,

    [string]$ConfigFile,

    # Preferred credential source - path to a per-client encrypted settings file
    # (produced by the existing VA settings-encryption process; see scripts/VA-Functions-Common.ps1
    # for the decrypt side used here).
    [string]$CustomerSettingsPath,

    # Only relevant with -CustomerSettingsPath. Passed through to Import-Settings;
    # leave blank to use its own default/env-var resolution (see scripts/VA-Functions-Common.ps1).
    [string]$KeyPath,

    [string]$OutputPath = ".\fortigate_export_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
)

# ---------------------------------------------------------------------------
# Optional (preferred): load FortiGate / ApiKey / Vdom from an encrypted
# CustomerSettings file via the shared Import-Settings function.
# CLI parameters always win if supplied; this fills in whatever's missing.
# ---------------------------------------------------------------------------
if ($CustomerSettingsPath) {
    $CommonScript = Join-Path $PSScriptRoot "..\..\..\..\scripts\VA-Functions-Common.ps1"
    if (-not (Test-Path -LiteralPath $CommonScript)) {
        Write-Error "Shared functions script not found: $CommonScript"
        exit 1
    }
    . $CommonScript

    $ImportParams = @{ SettingsPath = $CustomerSettingsPath }
    if ($KeyPath) { $ImportParams["KeyPath"] = $KeyPath }
    $CustomerSettings = Import-Settings @ImportParams

    # Flat shape (NetworkDevice, IpAddress, ApiKey, Smtp* - matches CustomerSettings.csv
    # columns directly), not nested - this is whatever the settings-encryption process
    # actually produces, not something this script's own opinion.
    if ([string]::IsNullOrWhiteSpace($FortiGate) -and $CustomerSettings.IpAddress) {
        $FortiGate = $CustomerSettings.IpAddress
    }
    if ([string]::IsNullOrWhiteSpace($ApiKey) -and $CustomerSettings.ApiKey) {
        $ApiKey = $CustomerSettings.ApiKey
    }
    if ([string]::IsNullOrWhiteSpace($Vdom) -and $CustomerSettings.Vdom) {
        $Vdom = $CustomerSettings.Vdom
    }
}

# ---------------------------------------------------------------------------
# Optional (legacy): load FortiGate / ApiKey / Vdom from a simple Key=Value
# plaintext text file. CLI parameters and -CustomerSettingsPath both win over
# this; it only fills in whatever's still missing; interactive prompt is the
# final fallback after that.
#
# Expected file format (one per line, Vdom line optional):
#   FortiGate=<fortigate-ip-or-host>:8443
#   ApiKey=your-api-key-here
#   Vdom=test
#
# SECURITY NOTE: this stores the API key in PLAINTEXT on disk. Restrict the
# file's NTFS permissions to your account only, and never commit it to a
# repo. Prefer -CustomerSettingsPath (encrypted) over this for anything
# beyond lab/test use.
# ---------------------------------------------------------------------------
if ($ConfigFile) {
    if (-not (Test-Path $ConfigFile)) {
        Write-Error "Config file not found: $ConfigFile"
        exit 1
    }

    $configData = @{}
    Get-Content $ConfigFile | ForEach-Object {
        $line = $_.Trim()
        # Skip blank lines and lines starting with # (comments)
        if ($line -and -not $line.StartsWith("#") -and $line.Contains("=")) {
            $parts = $line.Split("=", 2)
            $configData[$parts[0].Trim()] = $parts[1].Trim()
        }
    }

    if ([string]::IsNullOrWhiteSpace($FortiGate) -and $configData.ContainsKey("FortiGate")) {
        $FortiGate = $configData["FortiGate"]
    }
    if ([string]::IsNullOrWhiteSpace($ApiKey) -and $configData.ContainsKey("ApiKey")) {
        $ApiKey = $configData["ApiKey"]
    }
    if ([string]::IsNullOrWhiteSpace($Vdom) -and $configData.ContainsKey("Vdom")) {
        $Vdom = $configData["Vdom"]
    }
}

# ---------------------------------------------------------------------------
# Interactive prompts for anything still not set (no CLI param, no config file).
# FortiGate/IP is plain text; API key is masked (typed input hidden) and
# converted back to plain text only in memory for the Authorization header.
# ---------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($FortiGate)) {
    $FortiGate = Read-Host "Enter FortiGate IP or hostname (e.g. 203.0.113.10 or 203.0.113.10:8443)"
}

if ([string]::IsNullOrWhiteSpace($ApiKey)) {
    $secureKey = Read-Host "Enter FortiGate API key" -AsSecureString
    $ApiKey = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
    )
}

if ([string]::IsNullOrWhiteSpace($FortiGate) -or [string]::IsNullOrWhiteSpace($ApiKey)) {
    Write-Error "FortiGate address and API key are both required."
    exit 1
}

# ---------------------------------------------------------------------------
# Cert handling: PS7+ has -SkipCertificateCheck; PS5.1 needs a callback hack.
# ---------------------------------------------------------------------------
$IsPS7Plus = $PSVersionTable.PSVersion.Major -ge 7

if (-not $IsPS7Plus) {
    # Only add the type once per session
    if (-not ("TrustAllCertsPolicy" -as [type])) {
        Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(
        ServicePoint srvPoint, X509Certificate certificate,
        WebRequest request, int certificateProblem) {
        return true;
    }
}
"@
    }
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
}

# ---------------------------------------------------------------------------
# Helper: wrapper around Invoke-RestMethod that handles cert bypass on both versions
# ---------------------------------------------------------------------------
function Invoke-FGTApi {
    param(
        [string]$Uri
    )

    $headers = @{
        "Authorization" = "Bearer $ApiKey"
    }

    try {
        if ($IsPS7Plus) {
            return Invoke-RestMethod -Uri $Uri -Headers $headers -Method Get -SkipCertificateCheck -ErrorAction Stop
        }
        else {
            return Invoke-RestMethod -Uri $Uri -Headers $headers -Method Get -ErrorAction Stop
        }
    }
    catch {
        Write-Error "API call failed for $Uri : $($_.Exception.Message)"
        return $null
    }
}

$baseUrl = "https://$FortiGate/api/v2"

# Only append ?vdom=... (or &vdom=... if other params already present) when a vdom was actually supplied.
# Leaving -Vdom blank is correct for FortiGates that don't have VDOMs enabled.
$vdomQuery = if ([string]::IsNullOrWhiteSpace($Vdom)) { "" } else { "vdom=$Vdom" }

function Add-VdomParam {
    param([string]$Uri)
    if ([string]::IsNullOrWhiteSpace($vdomQuery)) { return $Uri }
    if ($Uri -match '\?') { return "$Uri&$vdomQuery" }
    else { return "$Uri?$vdomQuery" }
}

Write-Host "Connecting to FortiGate at $FortiGate $(if ($Vdom) { "(vdom: $Vdom)" } else { "(no vdom)" })..." -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 1. Get policy config (names, src/dst, action, status) - cmdb is every
#    configured policy, enabled AND disabled, and drives the results list.
# ---------------------------------------------------------------------------
Write-Host "Fetching policy configuration..." -ForegroundColor Cyan
$policyCfgUri = Add-VdomParam "$baseUrl/cmdb/firewall/policy"
$policyCfg = Invoke-FGTApi -Uri $policyCfgUri

if (-not $policyCfg -or -not $policyCfg.results) {
    Write-Error "Failed to retrieve policy configuration. Check connectivity, API key, and trusted host settings."
    exit 1
}

$policyCfgLookup = @{}
foreach ($p in $policyCfg.results) {
    $policyCfgLookup[$p.policyid] = $p
}

# ---------------------------------------------------------------------------
# 2. Get live policy hit counters (monitor API). Disabled policies aren't
#    loaded into the runtime firewall table, so this has no entry for them -
#    it's a lookup for whichever cmdb policies are actually active, not the
#    source of the policy list itself.
# ---------------------------------------------------------------------------
Write-Host "Fetching policy hit counters..." -ForegroundColor Cyan
$policyMonitorUri = Add-VdomParam "$baseUrl/monitor/firewall/policy"
$policyMonitor = Invoke-FGTApi -Uri $policyMonitorUri

if (-not $policyMonitor) {
    Write-Host "Warning: could not retrieve hit counters - hit/byte/packet fields will show as 0 for all policies." -ForegroundColor Yellow
}

$policyMonitorLookup = @{}
if ($policyMonitor -and $policyMonitor.results) {
    foreach ($entry in $policyMonitor.results) {
        $policyMonitorLookup[$entry.policyid] = $entry
    }
}

# ---------------------------------------------------------------------------
# 3. Join: iterate the union of both id sets, not just one or the other.
#    cmdb has every configured policy (enabled + disabled); monitor also
#    includes runtime-only entries with no cmdb object of their own - e.g.
#    policy 0, FortiGate's implicit default-deny policy.
# ---------------------------------------------------------------------------
$allPolicyIds = @($policyCfgLookup.Keys) + @($policyMonitorLookup.Keys) | Select-Object -Unique | Sort-Object

$policyResults = foreach ($policyId in $allPolicyIds) {
    $cfg = $policyCfgLookup[$policyId]
    $entry = $policyMonitorLookup[$policyId]
    [PSCustomObject]@{
        PolicyID      = $policyId
        Name          = $cfg.name
        SrcIntf       = ($cfg.srcintf.name -join ",")
        DstIntf       = ($cfg.dstintf.name -join ",")
        Action        = $cfg.action
        Status        = $cfg.status
        HitCount      = if ($entry) { $entry.hit_count } else { 0 }
        Bytes         = if ($entry) { $entry.bytes } else { 0 }
        Packets       = if ($entry) { $entry.packets } else { 0 }
        ActiveSessions = if ($entry) { $entry.active_sessions } else { 0 }
    }
}

# ---------------------------------------------------------------------------
# 3a. Optional: drop administratively disabled policies from the report.
# ---------------------------------------------------------------------------
if ($ExcludeDisabled) {
    $excludedCount = ($policyResults | Where-Object { $_.Status -eq "disable" }).Count
    $policyResults = $policyResults | Where-Object { $_.Status -ne "disable" }
    if ($excludedCount -gt 0) {
        Write-Host "Excluded $excludedCount disabled policies." -ForegroundColor DarkGray
    }
}

if ($ShowZeroHitOnly) {
    Write-Host "`n--- Policies with 0 Hit Count ---" -ForegroundColor Green
    $policyResults | Where-Object { $_.HitCount -eq 0 } | Sort-Object PolicyID | Format-Table -AutoSize
}
else {
    Write-Host "`n--- Policy Hit Counts ---" -ForegroundColor Green
    $policyResults | Sort-Object HitCount -Descending | Format-Table -AutoSize
}

# ---------------------------------------------------------------------------
# 4. Get VIP config
# ---------------------------------------------------------------------------
Write-Host "Fetching VIP configuration..." -ForegroundColor Cyan
$vipCfgUri = Add-VdomParam "$baseUrl/cmdb/firewall/vip"
$vipCfg = Invoke-FGTApi -Uri $vipCfgUri

$vipResults = @()
if ($vipCfg -and $vipCfg.results) {
    $vipResults = foreach ($v in $vipCfg.results) {
        # Find policies that reference this VIP as a destination, to approximate "VIP hits"
        $relatedPolicies = $policyResults | Where-Object {
            $policyCfgLookup[$_.PolicyID].dstaddr.name -contains $v.name
        }

        $totalHits    = ($relatedPolicies | Measure-Object -Property HitCount -Sum).Sum
        $totalBytes   = ($relatedPolicies | Measure-Object -Property Bytes -Sum).Sum
        $totalPackets = ($relatedPolicies | Measure-Object -Property Packets -Sum).Sum

        [PSCustomObject]@{
            VIPName        = $v.name
            ExtIP          = $v.extip
            MappedIP       = ($v.mappedip.range -join ",")
            Interface      = $v.extintf
            RelatedPolicies = ($relatedPolicies.PolicyID -join ",")
            TotalHitCount  = $totalHits
            TotalBytes     = $totalBytes
            TotalPackets   = $totalPackets
        }
    }
}

$zeroHitVips = $vipResults | Where-Object { $_.TotalHitCount -eq 0 }

Write-Host "`n--- VIPs with 0 Hit Count ---" -ForegroundColor Green
if ($zeroHitVips.Count -eq 0) {
    Write-Host "(none found - all VIPs have traffic)" -ForegroundColor DarkGray
}
else {
    $zeroHitVips | Sort-Object VIPName | Format-Table -AutoSize
}

# ---------------------------------------------------------------------------
# 5. Optional CSV export - always writes the full policy/VIP data (the raw
#    record of everything assessed, not just what's flagged), plus dedicated
#    zero-hit subset files when there's anything to flag.
# ---------------------------------------------------------------------------
if ($ExportCsv) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    Write-Host "`nExported CSVs to $OutputPath" -ForegroundColor Yellow

    $policyResults | Export-Csv -Path "$OutputPath\policy_hit_counts.csv" -NoTypeInformation
    Write-Host "  - policy_hit_counts.csv       ($($policyResults.Count) policies)" -ForegroundColor DarkGray

    $zeroHitPolicies = $policyResults | Where-Object { $_.HitCount -eq 0 }
    if ($zeroHitPolicies.Count -gt 0) {
        $zeroHitPolicies | Export-Csv -Path "$OutputPath\policy_zero_hit_counts.csv" -NoTypeInformation
        Write-Host "  - policy_zero_hit_counts.csv  ($($zeroHitPolicies.Count) policies)" -ForegroundColor DarkGray
    }

    if ($vipResults.Count -gt 0) {
        $vipResults | Export-Csv -Path "$OutputPath\vip_hit_counts.csv" -NoTypeInformation
        Write-Host "  - vip_hit_counts.csv          ($($vipResults.Count) VIPs)" -ForegroundColor DarkGray
    }

    if ($zeroHitVips.Count -gt 0) {
        $zeroHitVips | Export-Csv -Path "$OutputPath\vip_zero_hit_counts.csv" -NoTypeInformation
        Write-Host "  - vip_zero_hit_counts.csv     ($($zeroHitVips.Count) VIPs)" -ForegroundColor DarkGray
    }
}
