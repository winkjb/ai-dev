<#
.SYNOPSIS
    Reports which security/UTM profiles are enabled on each FortiGate firewall policy.

.DESCRIPTION
    Queries the FortiGate cmdb API for firewall policies and inspects each one for
    attached security profiles: Antivirus, IPS, Web Filter, DNS Filter, Application
    Control, SSL/SSH Inspection, File Filter, Email Filter (Spam), VoIP, ICAP, WAF,
    CASB, and Video Filter. Reports which are enabled per policy, and can isolate
    policies with NO security profiles attached at all - a common audit finding.

.NOTES
    Requires a FortiGate REST API admin with an API key (Bearer token).
    Tested against FortiOS 6.x/7.x REST API v2.
    -FortiGate and -ApiKey can be passed as parameters, loaded from a
    -ConfigFile, or left blank to be prompted for interactively at runtime
    (API key input is masked when prompted).

    Security profile fields vary somewhat by FortiOS version and by whether a
    policy is flow-based or proxy-based. This script checks the common field
    names across recent FortiOS releases; if your version uses a different
    field name for a specific profile type, it may show as "not set" even if
    something is configured through a different mechanism (e.g. profile groups).

.EXAMPLE
    # Fully interactive - prompts for FortiGate address and API key
    .\Get-FortiGateSecurityProfiles.ps1

.EXAMPLE
    .\Get-FortiGateSecurityProfiles.ps1 -FortiGate <fortigate-ip-or-host>:8443 -ApiKey "yourkeyhere" -Vdom root

.EXAMPLE
    # Only show policies with zero security profiles attached, plus CSV of just those
    .\Get-FortiGateSecurityProfiles.ps1 -ConfigFile ".\fortigate.cfg" -ShowNoProfilesOnly -ExportCsv

.EXAMPLE
    # Preferred: credentials pulled from an encrypted CustomerSettings file (see
    # scripts/VA-Functions-Common.ps1 for the decrypt side; the file itself is
    # produced by the existing VA settings-encryption process, not by this repo)
    .\Get-FortiGateSecurityProfiles.ps1 -CustomerSettingsPath "..\..\data\reference\customers\aqs\hq\CustomerSettings.txt" -ExcludeDisabled -ExportCsv

.EXAMPLE
    # Exclude administratively disabled policies from the audit entirely
    .\Get-FortiGateSecurityProfiles.ps1 -ConfigFile ".\fortigate.cfg" -ExcludeDisabled -ExportCsv
#>

[CmdletBinding()]
param(
    [string]$FortiGate,

    [string]$ApiKey,

    [string]$Vdom,

    [switch]$ExportCsv,

    [switch]$ShowNoProfilesOnly,

    [switch]$ExcludeDisabled,

    [string]$ConfigFile,

    # Preferred credential source - path to a per-client encrypted settings file
    # (produced by the existing VA settings-encryption process; see scripts/VA-Functions-Common.ps1
    # for the decrypt side used here).
    [string]$CustomerSettingsPath,

    # Only relevant with -CustomerSettingsPath. Passed through to Import-Settings;
    # leave blank to use its own default/env-var resolution (see scripts/VA-Functions-Common.ps1).
    [string]$KeyPath,

    [string]$OutputPath = ".\fortigate_secprofile_export_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
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
# plaintext text file. Same format/file as the hit-count script. CLI
# parameters and -CustomerSettingsPath both win over this; it only fills in
# what's still missing; interactive prompt is the final fallback after that.
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
        Write-Error "API call failed for $Uri : $($_.Exception.Message)"
        return $null
    }
}

$baseUrl = "https://$FortiGate/api/v2"
$vdomQuery = if ([string]::IsNullOrWhiteSpace($Vdom)) { "" } else { "vdom=$Vdom" }

function Add-VdomParam {
    param([string]$Uri)
    if ([string]::IsNullOrWhiteSpace($vdomQuery)) { return $Uri }
    if ($Uri -match '\?') { return "$Uri&$vdomQuery" }
    else { return "$Uri?$vdomQuery" }
}

Write-Host "Connecting to FortiGate at $FortiGate $(if ($Vdom) { "(vdom: $Vdom)" } else { "(no vdom)" })..." -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# Get full policy config - security profile fields live here, not in monitor API
# ---------------------------------------------------------------------------
Write-Host "Fetching policy configuration..." -ForegroundColor Cyan
$policyCfgUri = Add-VdomParam "$baseUrl/cmdb/firewall/policy"
$policyCfg = Invoke-FGTApi -Uri $policyCfgUri

if (-not $policyCfg -or -not $policyCfg.results) {
    Write-Error "Failed to retrieve policy configuration. Check connectivity, API key, and trusted host settings."
    exit 1
}

# ---------------------------------------------------------------------------
# Map of security profile fields to friendly display names.
# These are the common FortiOS field names for flow-based/proxy-based UTM
# profiles attached directly to a policy (not via a security-profile-group).
# ---------------------------------------------------------------------------
$profileFields = [ordered]@{
    "av-profile"          = "Antivirus"
    "ips-sensor"           = "IPS"
    "webfilter-profile"    = "Web Filter"
    "dnsfilter-profile"    = "DNS Filter"
    "application-list"     = "App Control"
    "ssl-ssh-profile"      = "SSL/SSH Inspection"
    "file-filter"          = "File Filter"
    "emailfilter-profile"  = "Email Filter (Spam)"
    "voip-profile"         = "VoIP"
    "icap-profile"         = "ICAP"
    "waf-profile"          = "WAF"
    "casb-profile"         = "CASB"
    "videofilter-profile"  = "Video Filter"
}

# ---------------------------------------------------------------------------
# Build per-policy result: which profiles are set, plus a security-profile-group
# check (profile-protocol-options / security-profile-group covers group-based setups)
# ---------------------------------------------------------------------------
$policyResults = foreach ($p in $policyCfg.results) {

    $enabledProfiles = [System.Collections.Generic.List[string]]::new()
    $profileDetail = [ordered]@{}

    foreach ($field in $profileFields.Keys) {
        $value = $p.$field
        # FortiGate returns either a plain string name, or an empty string/null when not set
        $isSet = -not [string]::IsNullOrWhiteSpace($value)
        $profileDetail[$profileFields[$field]] = if ($isSet) { $value } else { "" }
        if ($isSet) {
            $enabledProfiles.Add("$($profileFields[$field]):$value")
        }
    }

    # Security profile group (single field that bundles multiple profiles together)
    $hasProfileGroup = -not [string]::IsNullOrWhiteSpace($p.'security-profile-group')
    if ($hasProfileGroup) {
        $enabledProfiles.Add("Profile Group:$($p.'security-profile-group')")
    }

    # utm-status reflects whether UTM inspection is toggled on for this policy at all
    $utmStatus = $p.'utm-status'

    [PSCustomObject]@{
        PolicyID         = $p.policyid
        Name             = $p.name
        Action           = $p.action
        Status           = $p.status
        UtmStatus        = $utmStatus
        SecurityProfiles = ($enabledProfiles -join "; ")
        ProfileCount     = $enabledProfiles.Count
        Antivirus        = $profileDetail["Antivirus"]
        IPS              = $profileDetail["IPS"]
        WebFilter        = $profileDetail["Web Filter"]
        DNSFilter        = $profileDetail["DNS Filter"]
        AppControl       = $profileDetail["App Control"]
        SSLInspection    = $profileDetail["SSL/SSH Inspection"]
        FileFilter       = $profileDetail["File Filter"]
        EmailFilter      = $profileDetail["Email Filter (Spam)"]
        VoIP             = $profileDetail["VoIP"]
        ICAP             = $profileDetail["ICAP"]
        WAF              = $profileDetail["WAF"]
        CASB             = $profileDetail["CASB"]
        VideoFilter      = $profileDetail["Video Filter"]
        ProfileGroup     = if ($hasProfileGroup) { $p.'security-profile-group' } else { "" }
    }
}

# ---------------------------------------------------------------------------
# Optional: drop administratively disabled policies from the audit entirely.
# ---------------------------------------------------------------------------
if ($ExcludeDisabled) {
    $excludedCount = ($policyResults | Where-Object { $_.Status -eq "disable" }).Count
    $policyResults = $policyResults | Where-Object { $_.Status -ne "disable" }
    if ($excludedCount -gt 0) {
        Write-Host "Excluded $excludedCount disabled policies." -ForegroundColor DarkGray
    }
}

# ---------------------------------------------------------------------------
# Console output
# ---------------------------------------------------------------------------
$noProfilePolicies = $policyResults | Where-Object { $_.ProfileCount -eq 0 }

if ($ShowNoProfilesOnly) {
    Write-Host "`n--- Policies with NO Security Profiles Attached ---" -ForegroundColor Red
    if ($noProfilePolicies.Count -eq 0) {
        Write-Host "(none found - every policy has at least one security profile)" -ForegroundColor DarkGray
    }
    else {
        $noProfilePolicies | Select-Object PolicyID, Name, Action, Status, UtmStatus | Sort-Object PolicyID | Format-Table -AutoSize
    }
}
else {
    Write-Host "`n--- Security Profiles by Policy ---" -ForegroundColor Green
    $policyResults | Select-Object PolicyID, Name, Action, Status, UtmStatus, ProfileCount, SecurityProfiles |
        Sort-Object PolicyID | Format-Table -AutoSize -Wrap

    Write-Host "`n--- Policies with NO Security Profiles Attached ---" -ForegroundColor Red
    if ($noProfilePolicies.Count -eq 0) {
        Write-Host "(none found - every policy has at least one security profile)" -ForegroundColor DarkGray
    }
    else {
        $noProfilePolicies | Select-Object PolicyID, Name, Action, Status, UtmStatus | Sort-Object PolicyID | Format-Table -AutoSize
    }
}

Write-Host "`nSummary: $($policyResults.Count) total policies, $($noProfilePolicies.Count) with no security profiles attached." -ForegroundColor Yellow

# ---------------------------------------------------------------------------
# Optional CSV export - full detail always written when requested;
# a dedicated "no profiles" CSV is only created if any exist.
# ---------------------------------------------------------------------------
if ($ExportCsv) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

    $policyResults | Export-Csv -Path "$OutputPath\policy_security_profiles.csv" -NoTypeInformation
    Write-Host "`nExported CSVs to $OutputPath" -ForegroundColor Yellow
    Write-Host "  - policy_security_profiles.csv        ($($policyResults.Count) policies)" -ForegroundColor DarkGray

    if ($noProfilePolicies.Count -gt 0) {
        $noProfilePolicies | Export-Csv -Path "$OutputPath\policy_no_security_profiles.csv" -NoTypeInformation
        Write-Host "  - policy_no_security_profiles.csv     ($($noProfilePolicies.Count) policies)" -ForegroundColor DarkGray
    }
}
