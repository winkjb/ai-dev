<#
.SYNOPSIS
    Audits whether a multi-WAN FortiGate has a real, functioning failover
    mechanism in place - SD-WAN, or link monitors that are actually wired up.

.DESCRIPTION
    A WAN interface count of 2+ only matters if something is actually watching
    those links and reacting to a failure - and only if both links are actually
    in use. This checks, in order:

    - system/interface: counts WAN-role interfaces. This alone is the "poor
      man's" multi-WAN signal (IsMultiWanConfigured below) - a WAN-role
      interface can be configured but never actually routed (spare/decommissioned
      link left in place), which would be a false positive on its own.

    - system/sdwan: whether SD-WAN is enabled. If it is, that's treated as the
      site's failover mechanism and link-monitor hygiene isn't scored further
      (SD-WAN health-check auditing is its own can of worms - not built here).
      SD-WAN sites also skip the routing cross-check below and use the raw
      interface-role count instead, since SD-WAN routes via its own zone/rule
      logic, not classic per-WAN static routes.

    - router/static AND monitor/router/ipv4 (both per-VDOM, unlike the other
      checks below): router/static only shows manually-configured static
      routes - a DHCP-addressed WAN circuit gets its default route
      automatically from the DHCP lease with nothing in that table at all, so
      checking static config alone would silently miss DHCP WANs entirely, not
      just undercount them (Brad's catch, 2026-08-10). monitor/router/ipv4 is
      the live/active routing table and is used as the actual source of truth
      for "is this WAN interface routed right now" - it reflects static AND
      DHCP-learned AND any other dynamically-installed default routes
      uniformly. Falls back to the static-route device list only if the live
      table couldn't be read at all. Only interfaces confirmed routed (live
      table preferred) count toward the real multi-WAN signal (IsMultiWanActive)
      that drives the findings below; a configured-but-unrouted WAN interface
      is surfaced as its own informational finding instead of silently
      inflating the count - split by interface mode (system/interface's "mode"
      field), since an unrouted DHCP WAN (likely a dead lease/circuit) is a
      more urgent signal than an unrouted static-mode WAN (likely an
      intentional cold spare).

    - system/link-monitor: when SD-WAN isn't enabled, this is expected to be
      the failover mechanism instead. Flags monitors that are outright
      disabled, and separately flags monitors that are enabled but not wired
      to actually act on a failure (update-static-route disabled) - a monitor
      that only logs a down link without ever changing the route table is
      running in observe-only/testing mode, not doing its job. Cross-
      references the count of genuinely functional monitors against the
      count of actively-routed WAN interfaces (not the static-only default-
      route count, for the same DHCP-blind-spot reason as above) - the same
      comparison a previously-used static-config analyzer (qc-firewall-new.py,
      in this same folder) already made for existence/count against static
      routes specifically - this adds the enabled/functional distinction and
      the DHCP-aware denominator on top of that.

.NOTES
    Requires a FortiGate REST API admin with an API key (Bearer token).

    UNVERIFIED AGAINST A LIVE DEVICE (2026-08-10) - built from a mix of the
    qc-firewall-new.py reference script (parses "show full-configuration"
    text, not the REST API) and general FortiOS API knowledge; the field
    names below have NOT been confirmed against this org's actual FortiGates
    the way the admin-audit script's fields were. Treat findings from this
    script with more skepticism until run live once:
      - system/sdwan: assumed a singleton object with a "status" field and a
        "health-check" array. Response shape not confirmed.
      - system/link-monitor "update-static-route": this is the best-guess
        match for "testing mode" (monitor probes/logs but never updates
        routing on failure) - not confirmed against a real config.
      - router/static default-route detection: treats "dst" equal to or
        missing/blank as "0.0.0.0 0.0.0.0" as the default route, mirroring
        how trusthost1-10 use that same sentinel in the admin-audit script -
        consistent with known FortiOS convention, but not directly confirmed
        for this table.
      - monitor/router/ipv4 (added 2026-08-10 for the DHCP-WAN blind spot):
        assumed each entry has an "ip_mask" field (checked for exact string
        "0.0.0.0/0" to identify a default route) and an "interface" field
        naming the outgoing interface. Neither field name is confirmed against
        a real device - this is the least-verified part of the whole script.
      - system/interface "mode" field (dhcp vs static vs pppoe, etc.) for DHCP
        WAN detection - not directly confirmed, though this is a very standard
        FortiOS field name.
      - router/static and monitor/router/ipv4 are both treated as per-VDOM
        (like the policy/VIP collectors, -Vdom applies here) - system/interface,
        system/sdwan, and system/link-monitor are treated as global-scope, no
        -Vdom applied, matching the admin-audit script's system/interface
        handling.

    "Multi-WAN" base signal (2+ interfaces with role=wan) is the same detection
    qc-firewall-new.py already uses successfully against real configs; the
    routing cross-check on top of it (IsMultiWanActive) is new here, added
    2026-08-10 at Brad's suggestion to cut down false positives from a WAN-role
    interface that's configured but not actually routed - also unverified live.

.EXAMPLE
    # Fully interactive - prompts for FortiGate address and API key
    .\Get-FortiGateWanRedundancy.ps1

.EXAMPLE
    .\Get-FortiGateWanRedundancy.ps1 -FortiGate <fortigate-ip-or-host>:8443 -ApiKey "yourkeyhere" -Vdom root

.EXAMPLE
    # Only show WAN interfaces/link monitors with a finding, plus CSV of just those
    .\Get-FortiGateWanRedundancy.ps1 -ConfigFile ".\fortigate.cfg" -ShowFindingsOnly -ExportCsv

.EXAMPLE
    # Preferred: credentials pulled from an encrypted CustomerSettings file (see
    # scripts/Functions-VA-Common.ps1 for the decrypt side; the file itself is
    # produced by the existing VA settings-encryption process, not by this repo)
    .\Get-FortiGateWanRedundancy.ps1 -CustomerSettingsPath "..\..\data\reference\customers\aqs\hq\CustomerSettings.txt" -ExportCsv
#>

[CmdletBinding()]
param(
    [string]$FortiGate,

    [string]$ApiKey,

    [string]$Vdom,

    [switch]$ExportCsv,

    [switch]$ShowFindingsOnly,

    [string]$ConfigFile,

    # Preferred credential source - path to a per-client encrypted settings file
    # (produced by the existing VA settings-encryption process; see scripts/Functions-VA-Common.ps1
    # for the decrypt side used here).
    [string]$CustomerSettingsPath,

    # Only relevant with -CustomerSettingsPath. Passed through to Import-Settings;
    # leave blank to use its own default/env-var resolution (see scripts/Functions-VA-Common.ps1).
    [string]$KeyPath,

    [string]$OutputPath = ".\fortigate_wanredundancy_export_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
)

# ---------------------------------------------------------------------------
# Optional (preferred): load FortiGate / ApiKey / Vdom from an encrypted
# CustomerSettings file via the shared Import-Settings function.
# CLI parameters always win if supplied; this fills in whatever's missing.
# ---------------------------------------------------------------------------
if ($CustomerSettingsPath) {
    $CommonScript = Join-Path $PSScriptRoot "..\..\..\..\scripts\Functions-VA-Common.ps1"
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
# plaintext text file. Same format/file as the other FortiGate collectors.
# CLI parameters and -CustomerSettingsPath both win over this; it only fills
# in what's still missing; interactive prompt is the final fallback after that.
#
# SECURITY NOTE: the config file stores the API key in PLAINTEXT on disk.
# Restrict its NTFS permissions to your account only, never commit it to a
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
# Interactive prompts for anything still not set.
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
    param([string]$Uri)

    $headers = @{ "Authorization" = "Bearer $ApiKey" }

    try {
        if ($IsPS7Plus) {
            return Invoke-RestMethod -Uri $Uri -Headers $headers -Method Get -SkipCertificateCheck -ErrorAction Stop
        }
        else {
            return Invoke-RestMethod -Uri $Uri -Headers $headers -Method Get -ErrorAction Stop
        }
    }
    catch {
        $detail = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        Write-Error "API call failed for $Uri : $detail"
        return $null
    }
}

$baseUrl = "https://$FortiGate/api/v2"

# router/static is per-VDOM (routing tables are scoped like policy/VIP) -
# system/interface, system/sdwan, and system/link-monitor are global-scope,
# same reasoning as the admin-audit script's system/interface handling.
$vdomQuery = if ([string]::IsNullOrWhiteSpace($Vdom)) { "" } else { "vdom=$Vdom" }
function Add-VdomParam {
    param([string]$Uri)
    if ([string]::IsNullOrWhiteSpace($vdomQuery)) { return $Uri }
    if ($Uri -match '\?') { return "$Uri&$vdomQuery" }
    else { return "$Uri?$vdomQuery" }
}

Write-Host "Connecting to FortiGate at $FortiGate..." -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 1. Interfaces (system/interface) - global-scope. Determine multi-WAN.
# ---------------------------------------------------------------------------
Write-Host "Fetching interface configuration..." -ForegroundColor Cyan
$interfaceCfg = Invoke-FGTApi -Uri "$baseUrl/cmdb/system/interface"

if (-not $interfaceCfg -or -not $interfaceCfg.results) {
    Write-Error "Failed to retrieve interface configuration. Check connectivity, API key, and trusted host settings."
    exit 1
}

$wanInterfaceResults = @($interfaceCfg.results | Where-Object { $_.role -eq "wan" } | ForEach-Object {
    [PSCustomObject]@{
        Interface = $_.name
        Role      = $_.role
        VDOM      = $_.vdom
        Status    = $_.status
        # DHCP-addressed circuits get their default route automatically from the
        # DHCP lease - no cmdb/router/static entry exists for them at all, which
        # is exactly why routing detection below checks the live table, not just
        # static config.
        Mode      = $_.mode
    }
})
$wanInterfaceNames = @($wanInterfaceResults.Interface)

# Raw interface-role-count signal - kept for visibility, but NOT what drives the
# failover-mechanism findings below. A WAN-role interface with no route actually
# pointing to it (spare/decommissioned/not-yet-cabled) isn't really part of an
# active multi-WAN setup - see $isMultiWan below, computed after routes are fetched.
$isMultiWanConfigured = $wanInterfaceResults.Count -ge 2

# ---------------------------------------------------------------------------
# 2. SD-WAN (system/sdwan) - global-scope. Presence/enablement only; SD-WAN's
#    own health-check hygiene is not audited here (separate scope).
# ---------------------------------------------------------------------------
Write-Host "Fetching SD-WAN configuration..." -ForegroundColor Cyan
$sdwanCfg = Invoke-FGTApi -Uri "$baseUrl/cmdb/system/sdwan"

$sdwanEnabled = $false
$sdwanHealthCheckCount = 0
if ($sdwanCfg -and $sdwanCfg.results) {
    $sdwanEnabled = $sdwanCfg.results.status -eq "enable"
    $sdwanHealthCheckCount = @($sdwanCfg.results.'health-check').Count
}
else {
    Write-Host "Warning: could not retrieve SD-WAN configuration - treating SD-WAN as not enabled." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# 3. Default routes - TWO sources, deliberately. cmdb/router/static only shows
#    manually-configured static routes - a DHCP-addressed WAN circuit gets its
#    default route automatically from the DHCP lease with nothing in that table
#    at all (Brad's catch, 2026-08-10). Checking static config alone would
#    silently miss DHCP WANs entirely, not just undercount them, so the live/
#    active routing table (monitor/router/ipv4) is the actual source of truth
#    for "is this WAN interface routed right now" - it reflects static AND
#    DHCP-learned AND any other dynamically-installed default routes uniformly.
#    Both are per-VDOM.
# ---------------------------------------------------------------------------
Write-Host "Fetching static route configuration..." -ForegroundColor Cyan
$routeCfg = Invoke-FGTApi -Uri (Add-VdomParam "$baseUrl/cmdb/router/static")

$defaultRouteResults = @()
if ($routeCfg -and $routeCfg.results) {
    $defaultRouteResults = @($routeCfg.results | Where-Object {
        [string]::IsNullOrWhiteSpace($_.dst) -or $_.dst -eq "0.0.0.0 0.0.0.0"
    } | ForEach-Object {
        [PSCustomObject]@{
            SeqNum   = $_.'seq-num'
            Device   = $_.device
            Gateway  = $_.gateway
            Distance = [int]$_.distance
            Priority = [int]$_.priority
            Status   = $_.status
        }
    })
}
else {
    Write-Host "Warning: could not retrieve static route configuration - configured (static-only) default-route count will be 0." -ForegroundColor Yellow
}

Write-Host "Fetching live routing table..." -ForegroundColor Cyan
$liveRouteCfg = Invoke-FGTApi -Uri (Add-VdomParam "$baseUrl/monitor/router/ipv4")
$liveRoutingAvailable = [bool]($liveRouteCfg -and $liveRouteCfg.results)

$liveDefaultRouteInterfaces = @()
if ($liveRoutingAvailable) {
    $liveDefaultRouteInterfaces = @($liveRouteCfg.results | Where-Object { $_.ip_mask -eq "0.0.0.0/0" } | Select-Object -ExpandProperty interface -Unique)
}
else {
    Write-Host "Warning: could not retrieve live routing table - falling back to static-route config only, which will miss DHCP-learned default routes." -ForegroundColor Yellow
}

# Cross-reference WAN-role interfaces against actual routing rather than trusting
# interface role alone - cuts down false positives from a WAN-role interface that's
# configured but not actually in use (spare/decommissioned link left in place).
# Prefers the live table (catches DHCP-learned routes); falls back to the static
# config's device list only if the live table couldn't be read at all. SD-WAN
# routes via its own zone/rule logic rather than classic per-WAN routes, so this
# refinement only applies when SD-WAN isn't enabled; SD-WAN sites fall back to
# the raw interface-role count.
$routedInterfaceSource = if ($liveRoutingAvailable) { $liveDefaultRouteInterfaces } else { @($defaultRouteResults.Device) }
$wanInterfacesInRouting = @($routedInterfaceSource | Where-Object { $_ -in $wanInterfaceNames } | Select-Object -Unique)
$isMultiWan = if ($sdwanEnabled) { $isMultiWanConfigured } else { @($wanInterfacesInRouting).Count -ge 2 }

# ---------------------------------------------------------------------------
# 4. Link monitors (system/link-monitor) - global-scope. Expected failover
#    mechanism when SD-WAN isn't enabled.
# ---------------------------------------------------------------------------
Write-Host "Fetching link-monitor configuration..." -ForegroundColor Cyan
$linkMonitorCfg = Invoke-FGTApi -Uri "$baseUrl/cmdb/system/link-monitor"

$linkMonitorResults = @()
if ($linkMonitorCfg -and $linkMonitorCfg.results) {
    $linkMonitorResults = foreach ($lm in $linkMonitorCfg.results) {

        $status = $lm.status
        $updateStaticRoute = $lm.'update-static-route'
        $isEnabled = $status -eq "enable"
        # Treat missing/blank the same as "enable" (FortiOS default for this field is enable) -
        # only an explicit "disable" counts as observe-only/testing mode.
        $isWiredToFailover = $updateStaticRoute -ne "disable"
        $isFunctional = $isEnabled -and $isWiredToFailover

        $findings = [System.Collections.Generic.List[string]]::new()
        if (-not $isEnabled) {
            $findings.Add("Link monitor '$($lm.name)' is disabled")
        }
        if (-not $isWiredToFailover) {
            $findings.Add("Link monitor '$($lm.name)' is not wired to update routing on failure (monitoring/testing only - won't actually trigger failover)")
        }

        [PSCustomObject]@{
            Name              = $lm.name
            SrcIntf           = $lm.srcintf
            Server            = ($lm.server -join ",")
            Protocol          = $lm.protocol
            Status            = $status
            UpdateStaticRoute = $updateStaticRoute
            IsFunctional      = $isFunctional
            Findings          = ($findings -join "; ")
        }
    }
}
else {
    Write-Host "Warning: could not retrieve link-monitor configuration - link-monitor findings will be empty." -ForegroundColor Yellow
}

$functionalLinkMonitors = @($linkMonitorResults | Where-Object { $_.IsFunctional })

# ---------------------------------------------------------------------------
# Site-level summary finding - the actual point of this script: does a
# multi-WAN site have a real, working failover mechanism.
# ---------------------------------------------------------------------------
$siteFindings = [System.Collections.Generic.List[string]]::new()

# Informational, not necessarily a failover gap by itself - surfaced regardless
# of whether it ends up dropping $isMultiWan below, since it's worth knowing
# either way. Split by interface mode: a DHCP WAN with no active route is a
# real problem worth flagging harder (lease/circuit likely down, since DHCP
# WANs get routed automatically the moment they have a lease) - a static/other-
# mode WAN with no route is more likely an intentional cold spare.
if ($isMultiWanConfigured -and -not $sdwanEnabled -and $wanInterfacesInRouting.Count -lt $wanInterfaceResults.Count) {
    $unroutedWan = @($wanInterfaceResults | Where-Object { $_.Interface -notin $wanInterfacesInRouting })
    $unroutedDhcp = @($unroutedWan | Where-Object { $_.Mode -eq "dhcp" })
    $unroutedOther = @($unroutedWan | Where-Object { $_.Mode -ne "dhcp" })

    if ($unroutedDhcp.Count -gt 0) {
        $siteFindings.Add("DHCP WAN interface(s) with no active default route in the live routing table - possible lease/connectivity problem: $(($unroutedDhcp.Interface) -join ',')")
    }
    if ($unroutedOther.Count -gt 0) {
        $siteFindings.Add("$($wanInterfaceResults.Count) WAN-role interface(s) configured but $($unroutedOther.Count) have no active default route - possible unused/spare link(s): $(($unroutedOther.Interface) -join ',')")
    }
}

if ($isMultiWan) {
    if ($sdwanEnabled) {
        # SD-WAN present - treated as the failover mechanism, link-monitor
        # gaps aren't scored on top of it (see .NOTES / .DESCRIPTION).
    }
    elseif ($linkMonitorResults.Count -eq 0) {
        $siteFindings.Add("Multi-WAN site ($($wanInterfaceResults.Count) WAN interfaces) has no SD-WAN and no link monitors configured - no automated failover mechanism in place")
    }
    elseif ($functionalLinkMonitors.Count -eq 0) {
        $siteFindings.Add("Multi-WAN site has link monitor(s) configured but none are both enabled and wired to update routing - failover will not actually trigger")
    }
    elseif ($wanInterfacesInRouting.Count -gt $functionalLinkMonitors.Count) {
        # Uses the live-routed WAN count, not the static-only default-route count -
        # a DHCP WAN with an active route but no cmdb/router/static entry still
        # needs a link monitor covering it, same as a statically-routed one.
        $siteFindings.Add("Only $($functionalLinkMonitors.Count) functional link monitor(s) for $($wanInterfacesInRouting.Count) actively-routed WAN path(s)")
    }
}

$siteSummary = [PSCustomObject]@{
    IsMultiWanConfigured      = $isMultiWanConfigured
    IsMultiWanActive          = $isMultiWan
    WanInterfaceCount         = $wanInterfaceResults.Count
    DhcpWanInterfaceCount     = @($wanInterfaceResults | Where-Object { $_.Mode -eq "dhcp" }).Count
    WanInterfacesRoutedCount  = @($wanInterfacesInRouting).Count
    LiveRoutingTableAvailable = $liveRoutingAvailable
    SdwanEnabled              = $sdwanEnabled
    SdwanHealthCheckCount     = $sdwanHealthCheckCount
    DefaultRouteCount         = $defaultRouteResults.Count
    LinkMonitorCount          = $linkMonitorResults.Count
    FunctionalLinkMonitorCount = $functionalLinkMonitors.Count
    Findings                  = ($siteFindings -join "; ")
}

# ---------------------------------------------------------------------------
# Console output
# ---------------------------------------------------------------------------
$linkMonitorFindings = $linkMonitorResults | Where-Object { $_.Findings }

if ($ShowFindingsOnly) {
    Write-Host "`n--- Site Summary ---" -ForegroundColor Green
    $siteSummary | Format-Table -AutoSize -Wrap

    Write-Host "`n--- Link Monitors With Findings ---" -ForegroundColor Red
    if ($linkMonitorFindings.Count -eq 0) { Write-Host "(none found)" -ForegroundColor DarkGray }
    else { $linkMonitorFindings | Format-Table -AutoSize -Wrap }
}
else {
    Write-Host "`n--- Site Summary ---" -ForegroundColor Green
    $siteSummary | Format-Table -AutoSize -Wrap

    Write-Host "`n--- WAN Interfaces ---" -ForegroundColor Green
    if ($wanInterfaceResults.Count -eq 0) { Write-Host "(none found)" -ForegroundColor DarkGray }
    else { $wanInterfaceResults | Format-Table -AutoSize -Wrap }

    Write-Host "`n--- Default Routes ---" -ForegroundColor Green
    if ($defaultRouteResults.Count -eq 0) { Write-Host "(none found)" -ForegroundColor DarkGray }
    else { $defaultRouteResults | Format-Table -AutoSize -Wrap }

    Write-Host "`n--- Link Monitors ---" -ForegroundColor Green
    if ($linkMonitorResults.Count -eq 0) { Write-Host "(none found)" -ForegroundColor DarkGray }
    else { $linkMonitorResults | Format-Table -AutoSize -Wrap }
}

Write-Host "`nSummary: multi-WAN configured=$isMultiWanConfigured, active (routed)=$isMultiWan, SD-WAN enabled=$sdwanEnabled, $($linkMonitorResults.Count) link monitor(s) / $($functionalLinkMonitors.Count) functional, $($linkMonitorFindings.Count) with findings." -ForegroundColor Yellow
if ($siteSummary.Findings) {
    Write-Host "Site finding: $($siteSummary.Findings)" -ForegroundColor Red
}

# ---------------------------------------------------------------------------
# Optional CSV export - full detail always written when requested;
# dedicated "findings only" CSV created only if any exist.
# ---------------------------------------------------------------------------
if ($ExportCsv) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    Write-Host "`nExported CSVs to $OutputPath" -ForegroundColor Yellow

    $siteSummary | Export-Csv -Path "$OutputPath\wan_redundancy_summary.csv" -NoTypeInformation
    Write-Host "  - wan_redundancy_summary.csv      (1 record)" -ForegroundColor DarkGray

    $wanInterfaceResults | Export-Csv -Path "$OutputPath\wan_interfaces.csv" -NoTypeInformation
    Write-Host "  - wan_interfaces.csv              ($($wanInterfaceResults.Count) interfaces)" -ForegroundColor DarkGray

    $defaultRouteResults | Export-Csv -Path "$OutputPath\default_routes.csv" -NoTypeInformation
    Write-Host "  - default_routes.csv              ($($defaultRouteResults.Count) routes)" -ForegroundColor DarkGray

    $linkMonitorResults | Export-Csv -Path "$OutputPath\link_monitors.csv" -NoTypeInformation
    Write-Host "  - link_monitors.csv               ($($linkMonitorResults.Count) monitors)" -ForegroundColor DarkGray
    if ($linkMonitorFindings.Count -gt 0) {
        $linkMonitorFindings | Export-Csv -Path "$OutputPath\link_monitors_findings.csv" -NoTypeInformation
        Write-Host "  - link_monitors_findings.csv      ($($linkMonitorFindings.Count) monitors)" -ForegroundColor DarkGray
    }
}
