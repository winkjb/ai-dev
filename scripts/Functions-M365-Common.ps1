################################################################################################################### 
##
## This script contains M365 functions for dot sourcing
## Version 1.13
##
###################################################################################################################

function Map-Customer {

    # Data-driven as of 2026-08-13 (was a hardcoded hashtable here) - a bad row in the CSV
    # fails to match one customer; a bad hashtable entry could break parsing of this entire
    # file (has happened before, in a different Functions-*-Common.ps1). Lives at the
    # workspace-root data/reference/ level, not nested under program-management, since this
    # function is itself workspace-shared and customer lookups may end up needed by more than
    # one team long-term.

    param(
        [Parameter(Mandatory)]
        [string]$CustomerName,

        [string]$MapPath
    )

    if (-not $MapPath) { $MapPath = Join-Path $PSScriptRoot "..\data\reference\CustomerMap.csv" }
    if (-not (Test-Path -LiteralPath $MapPath)) { throw "Customer map not found: $MapPath" }

    $Row = Import-Csv -LiteralPath $MapPath -Encoding UTF8 | Where-Object { $_.CustomerName -eq $CustomerName }

    if (-not $Row) { throw "Customer '$CustomerName' was not found in customer map." }

    return [PSCustomObject]@{
        Directory      = $Row.Directory
        CustomerFolder = $Row.CustomerFolder
    }

}

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
        # Ensure directory exists
        Ensure-Directory -Path $Path
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

    param ([string]$sku)

    # Define a hashtable to map input names to friendly names
    $skuMapping = @{
        "AAD_BASIC"                                          = "Azure Active Directory Basic"
        "AAD_PREMIUM"                                        = "Azure Active Directory Premium P1"
        "AAD_PREMIUM_P2"                                     = "Azure Active Directory Premium P2"
        "Business_Assist_SMB_WD"                             = "Business Assist"
        "CPC_E_2C_8GB_256GB​"                                 = "Windows 365 Enterprise 2 vCPU, 8GB, 256GB"
        "CPC_E_4C_16GB_256GB​"                                = "Windows 365 Enterprise 4 vCPU, 16GB, 256GB"
        "CPC_E_4C_32GB_256GB​"                                = "Windows 365 Enterprise 8 vCPU, 32GB, 256GB"
        "Dynamics_365_Onboarding_SKU"                        = "Dynamics 365 Talent: Onboard"
        "EMSPREMIUM"                                         = "Enterprise Mobility + Security E5"
        "ENTERPRISEPACK"                                     = "O365 E3"
        "EXCHANGEARCHIVE_ADDON"                              = "Exchange Online Archiving"
        "EXCHANGESTANDARD"                                   = "Exchange Online (Plan 1)"
        "EXCHANGEENTERPRISE"                                 = "Exchange Online (Plan 2)"
        "FLOW_FREE"                                          = "Microsoft Power Automate Free"
        "Microsoft_365_Business_Basic_(no Teams)"            = "M365 Business Basic (No Teams)"
        "Microsoft_365_Copilot"                              = "M365 Copilot"
        "MICROSOFT_365_COPILOT_FOR_BUSINESS"                 = "M365 Copilot Business"
        "Microsoft_365_E3_(no_Teams)"                        = "M365 E3 (No Teams)"
        "Microsoft_365_E5_(no_Teams)"                        = "M365 E5 (No Teams)" 
        "Microsoft_BUSINESS_CENTER"                          = "Microsoft Business Center"
        "Microsoft_Entra_Private_Access_Premium"             = "Microsoft Entra Private Access"
        "Microsoft_Intune_Advanced_Analytics"                = "Microsoft Intune Advanced Analytics"
        "Microsoft_Intune_Endpoint_Privilege_Management"     = "Microsoft Intune Endpoint Privilege Management"
        "Microsoft_Teams_Audio_Conferencing_select_dial_out" = "Teams Audio Conferencing"
        "Microsoft_Teams_Exploratory_Dept"                   = "Teams (Exploratory)"
        "Microsoft_Teams_Enterprise_New"                     = "Teams Enterprise"
        "Microsoft_Teams_Premium"                            = "Teams Premium"
        "Microsoft_Teams_Rooms_Basic"                        = "Teams Rooms Basic"
        "Microsoft_Teams_Rooms_Pro"                          = "Teams Rooms Pro"
        "O365_BUSINESS"                                      = "M365 Apps for Business"
        "O365_BUSINESS_ESSENTIALS"                           = "M365 Business Basic"
        "O365_BUSINESS_PREMIUM"                              = "M365 Business Standard"
        "OFFICESUBSCRIPTION"                                 = "M365 Apps for Enterprise"
        "PBI_PREMIUM_P2_ADDON"                               = "Power BI Premium"
        "PBI_PREMIUM_PER_USER"                               = "Power BI Premium Per User"
        "POWERAUTOMATE_ATTENDED_RPA"                         = "Power Automate Premium"
        "POWER_BI_STANDARD"                                  = "Microsoft Fabric (Free)"
        "POWERAPPS_DEV"                                      = "Microsoft Power Apps for Developer"
        "POWERAPPS_PER_USER"                                 = "Microsoft Power Apps (Per User)"
        "POWERAPPS_VIRAL"                                    = "Microsoft Power Apps Plan 2"
        "POWER_BI_PRO"                                       = "Power BI Pro"
        "PROJECT_PLAN3_DEPT"                                 = "Planner and Project Plan 3" 
        "PROJECTPREMIUM"                                     = "Planner and Project Plan 5"
        "PROJECTPROFESSIONAL"                                = "Planner and Project Plan 3"
        "RIGHTSMANAGEMENT_ADHOC"                             = "Rights Management Adhoc"
        "RMSBASIC"                                           = "Rights Management Basic"
        "SHAREPOINTSTORAGE"                                  = "SharePoint Storage (GBs)" 
        "SPB"                                                = "M365 Business Premium"
        "SPE_E3"                                             = "M365 E3"
        "SPE_E5"                                             = "M365 E5"
        "SPE_F1"                                             = "M365 F3"
        "SPE_F5_COMP"                                        = "M365 F5 Compliance Add-on"
        "STANDARDPACK"                                       = "O365 E1"
        "STREAM"                                             = "Microsoft Stream"
        "TEAMS_ESSENTIALS_AAD"                               = "Teams Essentials"
        "Teams_Premium_(for_Departments)"                    = "Teams Premium (for Departments)"
        "VISIOCLIENT"                                        = "Visio Plan 2"
        "VISIOONLINE_PLAN1"                                  = "Visio Plan 1"
        "WINDOWS_STORE"                                      = "Windows Store"
    }

    # Return the friendly name if it exists in the mapping, otherwise return the original name
    if ($skuMapping.ContainsKey($sku)) {
        return $skuMapping[$sku]
    } else {
        return $sku
    }

}
