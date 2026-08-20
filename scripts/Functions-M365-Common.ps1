################################################################################################################### 
##
## This script contains M365 functions for dot sourcing
## Version 1.13
##
###################################################################################################################

# Token cache lives for the life of the PowerShell session/script
if (-not $script:GraphTokenCache) { $script:GraphTokenCache = @{} }

function Get-GraphToken {

    [CmdletBinding()]
    
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$CustomerSettings,
        [string]$Scope = 'https://graph.microsoft.com/.default',
        [int]$SkewSeconds = 300
    )

    if (-not $CustomerSettings.TenantDomain -or -not $CustomerSettings.ApplicationID -or -not $CustomerSettings.AccessSecret) {
        throw "API call missing customer settings."
    }

    $Tenant   = $CustomerSettings.TenantDomain
    $ClientId = $CustomerSettings.ApplicationID
    $CacheKey = "$Tenant||$ClientId||$Scope"

    if ($script:GraphTokenCache.ContainsKey($cacheKey)) {
        $Cached = $script:GraphTokenCache[$cacheKey]
        if ($Cached.ExpiresOnUtc.AddSeconds(-$SkewSeconds) -gt [DateTime]::UtcNow) {
            return $Cached.AccessToken
        }
    }

    $Uri = "https://login.microsoftonline.com/$tenant/oauth2/v2.0/token"
    $Body = @{
        tenant        = $Tenant
        client_id     = $ClientId
        client_secret = $CustomerSettings.AccessSecret
        scope         = $Scope
        grant_type    = 'client_credentials'
    }

    try {
        $Response = Invoke-RestMethod -Method Post -Uri $Uri -Body $Body -ContentType 'application/x-www-form-urlencoded'
        if (-not $Response.access_token) { throw "No access_token in response." }

        $ExpiresOnUtc = [DateTime]::UtcNow.AddSeconds([int]$Response.expires_in)

        $Script:GraphTokenCache[$CacheKey] = [pscustomobject]@{
            AccessToken  = $Response.access_token
            ExpiresOnUtc = $ExpiresOnUtc
        }
        return $Response.access_token
    } catch {
        throw "Get-GraphToken failed: $($_.Exception.Message)"
    }
}

function Get-All365Results {

    param(
        [string]$Uri, 
        [hashtable]$Headers
    )

    $Results = @()

    do {
        $Response = Invoke-RestMethod -Uri $Uri -Headers $Headers
        $Results += $Response.value
        $Uri = $Response.'@odata.nextLink'
    } while ($Uri)
    
    return $Results

}

function Invoke-GraphRequest {
    
    [CmdletBinding()]
    
    param (
        [Parameter(Mandatory)] [string]$Url,
        [Parameter(Mandatory)] [hashtable]$Headers,
        [int]$MaxRetries = 10,
        [int]$TimeoutSec = 120
    )

    $RetryCount = 0
    $Delay = 1

    while ($RetryCount -lt $MaxRetries) {
        try {
            return Invoke-RestMethod -Uri $Url -Headers $Headers -TimeoutSec $TimeoutSec
        } catch {
            $Response = $_.Exception.Response
            $Status = $null
            $RetryAfter = $null
            if ($Response) {
                try { $Status = [int]$Response.StatusCode } catch {}
                try { $RetryAfter = $Response.Headers['Retry-After'] } catch {}
            }

            if ($Status -in 429,503,504) {
                if ($RetryCount -ge ($MaxRetries - 1)) { throw }
                if ($RetryAfter) {
                    Start-Sleep -Seconds ([int]$RetryAfter)
                } else {
                    Start-Sleep -Seconds $Delay
                    $Delay = [Math]::Min($Delay * 2, 60) + (Get-Random -Minimum 0 -Maximum 3)
                }
                $RetryCount++
                continue
            }

            # Helpful diagnostics for 4xx
            if ($Response -and $Response.GetResponseStream()) {
                $Reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
                $Body = $Reader.ReadToEnd()
                Write-Host "Graph error $($Status): $body" -ForegroundColor Yellow
            }
            throw
        }
    }

    throw "Max retries reached. Unable to retrieve data."

}

function Get-LatestDate {

    param([array]$Dates)

    $ValidDates = $Dates | Where-Object { $_ }
    
    if (-not $ValidDates) { return $null }

    try {
        $NormalizedDates = $ValidDates | ForEach-Object { [datetime]$_ }

        return ($NormalizedDates | Sort-Object -Descending | Select-Object -First 1)
    }
    catch {
        return $null
    }  

}

function Write-IncrementalCsv {

    [CmdletBinding()]

    param(
        [Parameter(Mandatory=$true)]
        [string]$Path,
        [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
        [psobject]$InputObject
    )

    begin {
        # Ensure directory exists - Test-Directory (Functions-VA-Common.ps1) expects a
        # directory path, not a file path, so pass its parent rather than $Path itself.
        Test-Directory -Path (Split-Path $Path -Parent)
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        $newFile = -not (Test-Path -Path $Path)
        if ($newFile) {
            # Write header on first use
            $header = ($InputObject | ConvertTo-Csv -NoTypeInformation)[0]
            $sw = New-Object System.IO.StreamWriter($Path, $false, $utf8NoBom)
            $sw.WriteLine($header)
            $sw.Close()
        }
    } process {
        $line = ($InputObject | ConvertTo-Csv -NoTypeInformation | Select-Object -Skip 1) -join [Environment]::NewLine
        Add-Content -Path $Path -Value $line -Encoding UTF8
    }

}

function Get-FriendlyLicenseName {

    # Data-driven as of 2026-08-16 (was a hardcoded hashtable here) - same reasoning as
    # Map-Customer's move to CustomerMap.csv: a bad row in the CSV fails to resolve one SKU
    # name, a bad hashtable entry risks breaking parsing of this entire file. Cached per
    # resolved $MapPath (mirrors Get-GraphToken's $script:GraphTokenCache above) since this is
    # called once per license row/assignment by every caller, not once per script run.

    [CmdletBinding()]
    param(
        [string]$sku,
        [string]$MapPath
    )

    if (-not $MapPath) { $MapPath = Join-Path $PSScriptRoot "..\program-management\ait-m365\data\reference\LicenseSkuNames.csv" }

    if (-not $script:LicenseSkuNameCache) { $script:LicenseSkuNameCache = @{} }

    if (-not $script:LicenseSkuNameCache.ContainsKey($MapPath)) {

        $Map = @{}
        if (Test-Path -LiteralPath $MapPath) {
            foreach ($Row in (Import-Csv -LiteralPath $MapPath -Encoding UTF8)) {
                $Map[$Row.SkuPartNumber] = $Row.FriendlyName
            }
        }
        $script:LicenseSkuNameCache[$MapPath] = $Map

    }

    $SkuMap = $script:LicenseSkuNameCache[$MapPath]

    if ($SkuMap.ContainsKey($sku)) {
        return $SkuMap[$sku]
    } else {
        return $sku
    }

}
