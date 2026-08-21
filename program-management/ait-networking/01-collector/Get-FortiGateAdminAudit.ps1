<#
.SYNOPSIS
    Audits FortiGate admin accounts, admin-access exposure, and global admin
    hardening settings via REST API.

.DESCRIPTION
    Queries the FortiGate cmdb API for three things and flags common hardening
    gaps in each:

    - system/admin: every local admin account - profile, two-factor status,
      and whether any trusted-host restriction is configured. Flags super_admin
      accounts without 2FA, and any account with no trusted-host restriction
      (admin login allowed from any source IP).

    - system/interface: admin-access protocols (allowaccess) enabled per
      interface. Flags admin access (https/ssh/http/telnet/snmp/fgfm) enabled
      on a WAN-role interface, and insecure unencrypted protocols (http,
      telnet) enabled anywhere regardless of interface role. The WAN finding
      is cross-referenced against the admin-account trusted-host data above:
      if every admin account has a trusted-host restriction, that closes down
      who can actually reach the open port, so the finding is worded as
      "mitigated" rather than a flat exposure; if admin-account data couldn't
      be read at all, it says so explicitly instead of assuming either way.

    - system/global: idle admin timeout, failed-login lockout threshold, and
      two ServIT-specific standards (not generic FortiOS hardening) - HTTP-to-
      HTTPS redirect should be OFF, and the admin HTTPS port should be 8443.

    system/admin, system/interface, and system/global are global-scope objects
    in FortiOS (not per-VDOM), so unlike the policy/VIP collectors, no -Vdom
    query parameter is applied to these calls.

.NOTES
    Requires a FortiGate REST API admin with an API key (Bearer token).
    Tested against FortiOS 6.x/7.x REST API v2.
    -FortiGate and -ApiKey can be passed as parameters, loaded from a
    -ConfigFile, or left blank to be prompted for interactively at runtime
    (API key input is masked when prompted).

    KNOWN GAP, accepted as a manual check for now (confirmed live 2026-08-10):
    system/admin (the account/2FA/trusted-host data) reliably comes back empty
    for any account short of a genuinely full read-write super_admin profile -
    confirmed against both a custom profile granted read/write on every
    category, and a real user logged into the GUI as built-in Super Admin
    (read-only). Neither could see other administrators. This is not an
    auth-method issue (API key vs. username/password hits the identical
    restriction) and not fixable via profile permissions - FortiOS doesn't
    expose "view other admins" as a grantable category at all short of the
    true full-privilege super_admin profile. Provisioning a key at that
    privilege level for an unattended/scheduled script is a real security
    tradeoff (full read-write capability, not read-only, enforced by the
    script's own discipline rather than FortiOS), so for now the admin-account
    section of this report is expected to run as a no-op (the "zero accounts"
    warning) and that data gets pulled manually via the GUI instead. Revisit
    if a suitable elevated credential becomes available.

    A related consequence: the WAN-facing interface finding below can only
    say "trusted-host coverage unknown" rather than confirm mitigation, for
    as long as the admin-account data is unavailable.

    "Super admin" detection is based on accprofile -eq "super_admin" (the
    built-in profile name) - a custom profile with equivalent permissions
    won't be flagged. Two-factor field name and trusthost JSON shape can vary
    slightly by FortiOS version; this checks the common field names across
    recent releases.

.EXAMPLE
    # Fully interactive - prompts for FortiGate address and API key
    .\Get-FortiGateAdminAudit.ps1

.EXAMPLE
    .\Get-FortiGateAdminAudit.ps1 -FortiGate <fortigate-ip-or-host>:8443 -ApiKey "yourkeyhere"

.EXAMPLE
    # Only show accounts/interfaces/settings with a hardening finding, plus CSV of just those
    .\Get-FortiGateAdminAudit.ps1 -ConfigFile ".\fortigate.cfg" -ShowFindingsOnly -ExportCsv

.EXAMPLE
    # Preferred: credentials pulled from an encrypted CustomerSettings file (see
    # scripts/Functions-VA-Common.ps1 for the decrypt side; the file itself is
    # produced by the existing VA settings-encryption process, not by this repo)
    .\Get-FortiGateAdminAudit.ps1 -CustomerSettingsPath "..\..\data\reference\customers\aqs\hq\CustomerSettings.txt" -ExportCsv
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

    [string]$OutputPath = ".\fortigate_adminaudit_export_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
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
        # FortiGate returns a JSON error body (http_status/reason) on 403/400 etc. -
        # $_.ErrorDetails.Message carries that raw body when present; .Exception.Message
        # alone is often just "The remote server returned an error: (403) Forbidden."
        # with no indication of *why* (vdom scope vs. missing profile permission).
        $detail = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        Write-Error "API call failed for $Uri : $detail"
        return $null
    }
}

$baseUrl = "https://$FortiGate/api/v2"

# ---------------------------------------------------------------------------
# Org-specific standards (ServIT convention, not a generic FortiOS hardening
# rule) - isolated here so they're easy to lift into a data-driven baseline
# config later if an Analyst-role component gets built per
# program-management-agent-architecture.md, rather than staying hardcoded.
# ---------------------------------------------------------------------------
$StandardAdminPort = 8443
$StandardHttpsRedirectExpected = "disable"

Write-Host "Connecting to FortiGate at $FortiGate..." -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 1. Admin accounts (system/admin) - global-scope, no vdom param.
# ---------------------------------------------------------------------------
Write-Host "Fetching admin accounts..." -ForegroundColor Cyan
$adminCfg = Invoke-FGTApi -Uri "$baseUrl/cmdb/system/admin"

# $adminCfg is $null only when Invoke-FGTApi's own catch already reported the failure
# (bad connectivity/key/host) - that's fatal. A non-null response with zero/no results
# is a different situation: the call succeeded but returned nothing, which on FortiOS
# commonly means the API admin's profile isn't permitted to list *other* administrators
# even when it otherwise has broad read access (system/admin is treated as sensitive) -
# so this is a warning to investigate, not a hard failure, and the run continues with
# zero admin-account findings rather than aborting the whole audit.
if ($null -eq $adminCfg) {
    Write-Error "Failed to retrieve admin accounts. Check connectivity, API key, and trusted host settings."
    exit 1
}
if (@($adminCfg.results).Count -eq 0) {
    Write-Host "Warning: system/admin returned zero accounts. The API admin's profile likely can't list other administrators (a common FortiOS restriction even for profiles cloned from super_admin) - admin-account findings below will be empty; interface and global-settings findings are unaffected." -ForegroundColor Yellow
}

$adminResults = foreach ($a in $adminCfg.results) {

    $isSuperAdmin = $a.accprofile -eq "super_admin"

    # Field name varies by FortiOS release - check both known variants.
    $twoFactor = if ($a.'two-factor') { $a.'two-factor' } elseif ($a.'two-factor-authentication') { $a.'two-factor-authentication' } else { "disable" }
    $twoFactorEnabled = $twoFactor -and $twoFactor -ne "disable"

    # trusthost1-10: default/unset value is "0.0.0.0 0.0.0.0" (any source allowed).
    # Any field populated with something else counts as a restriction configured.
    $trustHosts = for ($i = 1; $i -le 10; $i++) {
        $val = $a."trusthost$i"
        if ($val -and $val -ne "0.0.0.0 0.0.0.0") { $val }
    }
    $hasTrustedHosts = @($trustHosts).Count -gt 0

    $findings = [System.Collections.Generic.List[string]]::new()
    if ($isSuperAdmin -and -not $twoFactorEnabled) {
        $findings.Add("Super admin without 2FA")
    }
    if (-not $hasTrustedHosts) {
        $findings.Add("No trusted-host restriction (admin access allowed from any IP)")
    }

    [PSCustomObject]@{
        Name             = $a.name
        AccessProfile    = $a.accprofile
        IsSuperAdmin     = $isSuperAdmin
        VDOM             = ($a.vdom.name -join ",")
        RemoteAuth       = [bool]$a.'remote-auth'
        TwoFactor        = $twoFactor
        TrustedHosts     = ($trustHosts -join "; ")
        TrustedHostCount = @($trustHosts).Count
        Findings         = ($findings -join "; ")
    }
}

# A WAN interface with admin ports open isn't necessarily "exposed" - if every admin
# account has a trusted-host restriction, that closes the actual attack surface down to
# just those IPs regardless of what the interface itself allows. Cross-reference the two
# rather than flagging the interface in isolation. When admin-account data couldn't be
# read at all (see the zero-accounts warning above), this can't be determined either way -
# the finding language below says so explicitly instead of guessing.
$adminDataAvailable = @($adminResults).Count -gt 0
$allAdminsHaveTrustedHosts = $adminDataAvailable -and (@($adminResults | Where-Object { $_.TrustedHostCount -eq 0 }).Count -eq 0)

# ---------------------------------------------------------------------------
# 2. Interface admin-access exposure (system/interface) - global-scope.
# ---------------------------------------------------------------------------
Write-Host "Fetching interface configuration..." -ForegroundColor Cyan
$interfaceCfg = Invoke-FGTApi -Uri "$baseUrl/cmdb/system/interface"

$interfaceResults = @()
if ($interfaceCfg -and $interfaceCfg.results) {
    $interfaceResults = foreach ($i in $interfaceCfg.results) {

        # allowaccess comes back as one space-delimited string (e.g. "ping https ssh snmp
        # fgfm"), not a JSON array - must split before doing per-protocol membership checks.
        $allowAccess = @(($i.allowaccess -split '\s+') | Where-Object { $_ })
        $isWanFacing = $i.role -eq "wan"
        $adminProtocols = @($allowAccess | Where-Object { $_ -in @("https", "ssh", "http", "telnet", "snmp", "fgfm") })
        $insecureProtocols = @($allowAccess | Where-Object { $_ -in @("http", "telnet") })

        $findings = [System.Collections.Generic.List[string]]::new()
        if ($isWanFacing -and $adminProtocols.Count -gt 0) {
            if (-not $adminDataAvailable) {
                $findings.Add("Admin access enabled on WAN-facing interface: $($adminProtocols -join ',') (trusted-host coverage unknown - admin account data could not be read)")
            }
            elseif ($allAdminsHaveTrustedHosts) {
                $findings.Add("Admin access enabled on WAN-facing interface: $($adminProtocols -join ',') (mitigated - every admin account has a trusted-host restriction configured)")
            }
            else {
                $findings.Add("Admin access exposed on WAN-facing interface: $($adminProtocols -join ',') - at least one admin account has no trusted-host restriction")
            }
        }
        if ($insecureProtocols.Count -gt 0) {
            $findings.Add("Insecure/unencrypted admin protocol enabled: $($insecureProtocols -join ',')")
        }

        [PSCustomObject]@{
            Interface   = $i.name
            Role        = $i.role
            VDOM        = $i.vdom
            AllowAccess = ($allowAccess -join ",")
            IsWanFacing = $isWanFacing
            Findings    = ($findings -join "; ")
        }
    }
}
else {
    Write-Host "Warning: could not retrieve interface configuration - interface access findings will be empty." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# 3. Global admin hardening settings (system/global) - global-scope, single object.
# ---------------------------------------------------------------------------
Write-Host "Fetching global admin settings..." -ForegroundColor Cyan
$globalCfg = Invoke-FGTApi -Uri "$baseUrl/cmdb/system/global"

$globalResult = $null
if ($globalCfg -and $globalCfg.results) {
    $g = $globalCfg.results

    $adminTimeout = [int]$g.admintimeout
    $lockoutThreshold = [int]$g.'admin-lockout-threshold'
    $httpsRedirect = $g.'admin-https-redirect'
    $adminPort = [int]$g.'admin-sport'

    $findings = [System.Collections.Generic.List[string]]::new()
    if ($adminTimeout -eq 0) {
        $findings.Add("Idle admin timeout disabled")
    }
    elseif ($adminTimeout -gt 15) {
        $findings.Add("Idle admin timeout longer than 15 minutes ($adminTimeout)")
    }
    if ($lockoutThreshold -eq 0) {
        $findings.Add("No failed-login lockout threshold configured")
    }
    if ($httpsRedirect -ne $StandardHttpsRedirectExpected) {
        $findings.Add("HTTP-to-HTTPS redirect is '$httpsRedirect' - ServIT standard expects '$StandardHttpsRedirectExpected'")
    }
    if ($adminPort -ne $StandardAdminPort) {
        $findings.Add("Admin HTTPS port is $adminPort - ServIT standard expects $StandardAdminPort")
    }

    $globalResult = [PSCustomObject]@{
        AdminTimeoutMinutes   = $adminTimeout
        AdminLockoutThreshold = $lockoutThreshold
        AdminLockoutDuration  = [int]$g.'admin-lockout-duration'
        AdminHttpsRedirect    = $httpsRedirect
        AdminPort             = $adminPort
        Findings              = ($findings -join "; ")
    }
}
else {
    Write-Host "Warning: could not retrieve global settings - global hardening findings will be empty." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Console output
# ---------------------------------------------------------------------------
$adminFindings = $adminResults | Where-Object { $_.Findings }
$interfaceFindings = $interfaceResults | Where-Object { $_.Findings }
$globalHasFindings = $globalResult -and $globalResult.Findings

if ($ShowFindingsOnly) {
    Write-Host "`n--- Admin Accounts With Findings ---" -ForegroundColor Red
    if ($adminFindings.Count -eq 0) { Write-Host "(none found)" -ForegroundColor DarkGray }
    else { $adminFindings | Format-Table -AutoSize -Wrap }

    Write-Host "`n--- Interfaces With Findings ---" -ForegroundColor Red
    if ($interfaceFindings.Count -eq 0) { Write-Host "(none found)" -ForegroundColor DarkGray }
    else { $interfaceFindings | Format-Table -AutoSize -Wrap }

    Write-Host "`n--- Global Settings Findings ---" -ForegroundColor Red
    if (-not $globalHasFindings) { Write-Host "(none found)" -ForegroundColor DarkGray }
    else { $globalResult | Format-Table -AutoSize -Wrap }
}
else {
    Write-Host "`n--- Admin Accounts ---" -ForegroundColor Green
    $adminResults | Format-Table -AutoSize -Wrap

    Write-Host "`n--- Interface Admin-Access ---" -ForegroundColor Green
    $interfaceResults | Format-Table -AutoSize -Wrap

    Write-Host "`n--- Global Admin Settings ---" -ForegroundColor Green
    if ($globalResult) { $globalResult | Format-Table -AutoSize -Wrap }
}

Write-Host "`nSummary: $($adminResults.Count) admin account(s) / $($adminFindings.Count) with findings, $($interfaceResults.Count) interface(s) / $($interfaceFindings.Count) with findings, global settings $(if ($globalHasFindings) { '1 finding' } else { 'no findings' })." -ForegroundColor Yellow

# ---------------------------------------------------------------------------
# Optional CSV export - full detail always written when requested;
# dedicated "findings only" CSVs created only if any exist.
# ---------------------------------------------------------------------------
if ($ExportCsv) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    Write-Host "`nExported CSVs to $OutputPath" -ForegroundColor Yellow

    $adminResults | Export-Csv -Path "$OutputPath\admin_accounts.csv" -NoTypeInformation
    Write-Host "  - admin_accounts.csv            ($($adminResults.Count) accounts)" -ForegroundColor DarkGray
    if ($adminFindings.Count -gt 0) {
        $adminFindings | Export-Csv -Path "$OutputPath\admin_accounts_findings.csv" -NoTypeInformation
        Write-Host "  - admin_accounts_findings.csv   ($($adminFindings.Count) accounts)" -ForegroundColor DarkGray
    }

    $interfaceResults | Export-Csv -Path "$OutputPath\interface_access.csv" -NoTypeInformation
    Write-Host "  - interface_access.csv          ($($interfaceResults.Count) interfaces)" -ForegroundColor DarkGray
    if ($interfaceFindings.Count -gt 0) {
        $interfaceFindings | Export-Csv -Path "$OutputPath\interface_access_findings.csv" -NoTypeInformation
        Write-Host "  - interface_access_findings.csv ($($interfaceFindings.Count) interfaces)" -ForegroundColor DarkGray
    }

    if ($globalResult) {
        $globalResult | Export-Csv -Path "$OutputPath\global_admin_settings.csv" -NoTypeInformation
        Write-Host "  - global_admin_settings.csv     (1 record)" -ForegroundColor DarkGray
    }
}
