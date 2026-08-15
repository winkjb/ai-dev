################################################################################################################### 
##
## This script contains common/shared Virtual Administrator functions to dot source
## Version 1.0
##
###################################################################################################################

function Import-Settings {
    
    [CmdletBinding()]
    
    param(
        [Parameter(Mandatory)]
        [string]$SettingsPath,

        # Falls back to $env:VA_KEY_PATH when set, then the default below - lets the key
        # location be overridden per-machine/service-account without editing every caller.
        [string]$KeyPath = $(if ($env:VA_KEY_PATH) { $env:VA_KEY_PATH } else { "C:\VA\data\reference\Key.txt" })
    )

    if (-not (Test-Path -LiteralPath $SettingsPath)) { throw "Settings file not found: $SettingsPath" }
    if (-not (Test-Path -LiteralPath $KeyPath))      { throw "Key file not found: $KeyPath" }

    try {
        
        $Key = Get-Content -LiteralPath $KeyPath
        [System.Array]::Reverse($Key)

        $SecureString = Get-Content -LiteralPath $SettingsPath | ConvertTo-SecureString -Key $Key

        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
        $JsonData = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

        $Settings = $JsonData | ConvertFrom-Json
        if (-not $Settings) { throw "Failed to parse JSON from $SettingsPath" }
        return $Settings
    
    }
    catch {
    
        throw "Import-Settings failed: $($_.Exception.Message)"
    
    }

}

function Map-Customer {

    # Data-driven as of 2026-08-13 (was a hardcoded hashtable here) - a bad row in the CSV
    # fails to match one customer; a bad hashtable entry could break parsing of this entire
    # file (has happened before, in a different Functions-*-Common.ps1). Lives here (not
    # Functions-M365-Common.ps1) since customer lookups are workspace-shared, not M365-specific.

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
        Directory        = $Row.Directory
        SharepointFolder = $Row.SharepointFolder
        FromAddress      = $Row.FromAddress
    }

}

function Test-Directory {

    param (
        [Parameter(Mandatory=$true)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        try {
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
            Write-Verbose "Created directory: $Path"
        } catch {
            throw "Failed to create directory $Path. Error: $_"
        }
    }

}

function Write-ToLog {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$LogFile,

        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet("INFO","WARN","ERROR","SUCCESS","SKIP")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"
    Add-Content -Path $LogFile -Value $line
    switch ($Level) {
        "ERROR"   { Write-Host $line -ForegroundColor Red }
        "WARN"    { Write-Host $line -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $line -ForegroundColor Green }
        "SKIP"    { Write-Host $line -ForegroundColor DarkGray }
        default   { Write-Host $line }
    }

}

function Get-DaysSince {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        $Value,

        # Exact format for TryParseExact (e.g. "MM/dd/yyyy hh:mm tt"). Omit for free-form parsing (ISO 8601, etc).
        [string]$Format,

        # Treat a numeric $Value as Unix epoch seconds instead of a date string.
        [switch]$Epoch,

        [datetime]$Reference = (Get-Date)
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }

    $Parsed = $null

    if ($Value -is [datetime]) {

        $Parsed = $Value

    } elseif ($Epoch) {

        $Seconds = 0.0
        if ([double]::TryParse([string]$Value, [ref]$Seconds)) {
            $Parsed = [datetime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc).AddSeconds($Seconds)
        }

    } elseif ($Format) {

        $Temp = [datetime]::MinValue
        if ([datetime]::TryParseExact([string]$Value, $Format, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$Temp)) {
            $Parsed = $Temp
        }

    } else {

        $Temp = [datetime]::MinValue
        if ([datetime]::TryParse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$Temp)) {
            $Parsed = $Temp
        }

    }

    if (-not $Parsed) { return $null }

    # Truncate toward zero rather than round to nearest - a login 23 hours ago should read
    # as 0 days, not 1.
    return [int][math]::Truncate(($Reference - $Parsed).TotalDays)

}

function Add-ToIndex {

    param(
        [hashtable]$Index,
        [string]$Key,
        $Value
    )

    if (-not $Index.ContainsKey($Key)) { $Index[$Key] = @() }
    $Index[$Key] += $Value

}

function Send-Results {

    # Create parameters
    param (
        [string]$SmtpServer,
        [int]$Port,
        [string]$From,
        [string[]]$To,
        [string]$Subject,
        [string]$Body,
        [bool]$BodyAsHtml = $true,
        [string]$Priority = "Normal",
        [string[]]$Attachments = $null,
        [bool]$UseSsl = $false,
        [pscredential]$Credentials = $null
    )

    # Prepare parameters for Send-MailMessage
    $MessageParams = @{
        SmtpServer    = $SmtpServer
        Port          = $Port
        From          = $From
        To            = $To
        Subject       = $Subject
        Body          = $Body
        BodyAsHtml    = $BodyAsHtml
        Priority      = $Priority
        Encoding      = "UTF8"
        ErrorAction   = "Stop"
    }

    if ($UseSsl) { $MessageParams["UseSsl"] = $true }
    if ($Attachments) { $MessageParams["Attachments"] = $Attachments }
    if ($Credentials) { $MessageParams["Credential"] = $Credentials }

    try {
        Send-MailMessage @MessageParams
        Write-Host "Audit results emailed to $To."
    } catch {
        Write-Host "Error: Failed to email CSV log to $To via $SmtpServer."
        Write-Host "Details: $($_.Exception.Message)"
        # Re-throw so callers actually see the failure - swallowing it here meant every
        # caller's own try/catch (including "did the audit run succeed" logging) thought
        # a failed send was a success.
        throw
    }

}