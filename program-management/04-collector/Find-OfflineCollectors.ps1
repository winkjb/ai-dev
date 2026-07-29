<#
.SYNOPSIS
    Pulls running/backed-up firewall configurations for all tenants from the Auvik API
    and saves them locally for evaluation.

.DESCRIPTION
    - Authenticates to Auvik via HTTP Basic Auth (username + API key)
    - Enumerates all tenants (paginated)
    - For each tenant, pulls firewall device configuration backups (paginated)
    - Saves each config to a per-tenant folder, decoding base64 payloads if present
    - Throttles requests to respect Auvik's rate limits
    - Writes a summary CSV of what was pulled vs. what was unavailable

.NOTES
    Region: US5 (auvikapi.us5.my.auvik.com)
    Requires: Auvik API key with read access across managed tenants
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AuvikUsername,

    [Parameter(Mandatory = $true)]
    [string]$AuvikApiKey,

    [string]$Region = "us5",

    [string]$OutputRoot = ".\AuvikFirewallConfigs",

    [int]$ThrottleMs = 400,          # delay between API calls (ms)

    [int]$PageSize = 100
)

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

$BaseUri = "https://auvikapi.$Region.my.auvik.com/v1"

$b64Creds = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($AuvikUsername):$($AuvikApiKey)"))
$Headers = @{
    Authorization = "Basic $b64Creds"
    "Content-Type" = "application/json"
}

if (-not (Test-Path $OutputRoot)) {
    New-Item -ItemType Directory -Path $OutputRoot | Out-Null
}

$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$SummaryPath = Join-Path $OutputRoot "PullSummary_$Timestamp.csv"
$Summary = [System.Collections.Generic.List[object]]::new()

function Invoke-AuvikRequest {
    param(
        [string]$Uri
    )
    try {
        $response = Invoke-RestMethod -Uri $Uri -Headers $Headers -Method Get -ErrorAction Stop
        Start-Sleep -Milliseconds $ThrottleMs
        return $response
    }
    catch {
        Write-Warning "Request failed: $Uri`n$($_.Exception.Message)"
        Start-Sleep -Milliseconds $ThrottleMs
        return $null
    }
}

function Get-AllPages {
    param(
        [string]$InitialUri
    )
    $allResults = [System.Collections.Generic.List[object]]::new()
    $uri = $InitialUri

    while ($uri) {
        $resp = Invoke-AuvikRequest -Uri $uri
        if (-not $resp) { break }

        if ($resp.data) {
            foreach ($item in $resp.data) { $allResults.Add($item) }
        }

        # Auvik uses JSON:API style pagination links
        $uri = $resp.links.next
    }

    return $allResults
}

# ---------------------------------------------------------------------------
# Step 1: Enumerate all tenants
# ---------------------------------------------------------------------------

Write-Host "Fetching tenant list..." -ForegroundColor Cyan
$tenantsUri = "$BaseUri/tenants?page[first]=$PageSize"
$tenants = Get-AllPages -InitialUri $tenantsUri

if (-not $tenants -or $tenants.Count -eq 0) {
    Write-Error "No tenants returned. Check credentials, region, and API access scope."
    return
}

Write-Host "Found $($tenants.Count) tenant(s)." -ForegroundColor Green

# ---------------------------------------------------------------------------
# Step 2: Loop tenants, pull firewall configs
# ---------------------------------------------------------------------------

$tenantIndex = 0
foreach ($tenant in $tenants) {
    $tenantIndex++
    $tenantId   = $tenant.id
    $tenantName = $tenant.attributes.deviceName
    if (-not $tenantName) { $tenantName = $tenant.attributes.name }
    if (-not $tenantName) { $tenantName = $tenantId }

    $safeTenantName = ($tenantName -replace '[\\/:*?"<>|]', '_').Trim()
    Write-Host "[$tenantIndex/$($tenants.Count)] Processing tenant: $safeTenantName" -ForegroundColor Yellow

    $tenantFolder = Join-Path $OutputRoot $safeTenantName
    if (-not (Test-Path $tenantFolder)) {
        New-Item -ItemType Directory -Path $tenantFolder | Out-Null
    }

    # Pull firewall device inventory for this tenant first (so we know which
    # devices SHOULD have configs, even if the config pull comes back empty)
    $deviceUri = "$BaseUri/inventory/device?tenants=$tenantId&filter[deviceType]=firewall&page[first]=$PageSize"
    $firewallDevices = Get-AllPages -InitialUri $deviceUri

    if (-not $firewallDevices -or $firewallDevices.Count -eq 0) {
        Write-Host "    No firewall devices found for this tenant." -ForegroundColor DarkGray
        $Summary.Add([pscustomobject]@{
            Tenant       = $safeTenantName
            TenantId     = $tenantId
            DeviceName   = "N/A"
            DeviceId     = "N/A"
            ConfigPulled = $false
            Reason       = "No firewall devices in inventory"
        })
        continue
    }

    # Pull configuration backups for this tenant
    $configUri = "$BaseUri/inventory/configuration?tenants=$tenantId&filter[deviceType]=firewall&page[first]=$PageSize"
    $configs = Get-AllPages -InitialUri $configUri

    # Index configs by deviceId for lookup
    $configByDevice = @{}
    foreach ($cfg in $configs) {
        $devId = $cfg.relationships.device.data.id
        if ($devId) { $configByDevice[$devId] = $cfg }
    }

    foreach ($device in $firewallDevices) {
        $deviceId   = $device.id
        $deviceName = $device.attributes.deviceName
        if (-not $deviceName) { $deviceName = $deviceId }
        $safeDeviceName = ($deviceName -replace '[\\/:*?"<>|]', '_').Trim()

        if ($configByDevice.ContainsKey($deviceId)) {
            $cfg = $configByDevice[$deviceId]
            $rawConfig = $cfg.attributes.configFile
            if (-not $rawConfig) { $rawConfig = $cfg.attributes.config }

            if ($rawConfig) {
                $outFile = Join-Path $tenantFolder "$safeDeviceName.cfg"
                try {
                    # Attempt base64 decode; fall back to raw text if it isn't base64
                    $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($rawConfig))
                    Set-Content -Path $outFile -Value $decoded -Encoding UTF8
                }
                catch {
                    Set-Content -Path $outFile -Value $rawConfig -Encoding UTF8
                }

                Write-Host "    Saved config: $safeDeviceName" -ForegroundColor Green
                $Summary.Add([pscustomobject]@{
                    Tenant       = $safeTenantName
                    TenantId     = $tenantId
                    DeviceName   = $safeDeviceName
                    DeviceId     = $deviceId
                    ConfigPulled = $true
                    Reason       = ""
                })
            }
            else {
                Write-Host "    Config record exists but no payload for: $safeDeviceName" -ForegroundColor DarkYellow
                $Summary.Add([pscustomobject]@{
                    Tenant       = $safeTenantName
                    TenantId     = $tenantId
                    DeviceName   = $safeDeviceName
                    DeviceId     = $deviceId
                    ConfigPulled = $false
                    Reason       = "Config record present but empty payload"
                })
            }
        }
        else {
            Write-Host "    No config backup available for: $safeDeviceName" -ForegroundColor DarkGray
            $Summary.Add([pscustomobject]@{
                Tenant       = $safeTenantName
                TenantId     = $tenantId
                DeviceName   = $safeDeviceName
                DeviceId     = $deviceId
                ConfigPulled = $false
                Reason       = "No configuration backup returned by Auvik"
            })
        }
    }
}

# ---------------------------------------------------------------------------
# Step 3: Write summary
# ---------------------------------------------------------------------------

$Summary | Export-Csv -Path $SummaryPath -NoTypeInformation
Write-Host "`nDone. Summary written to $SummaryPath" -ForegroundColor Cyan
$pulledCount = ($Summary | Where-Object { $_.ConfigPulled }).Count
Write-Host "Configs pulled: $pulledCount of $($Summary.Count) firewall device records." -ForegroundColor Cyan