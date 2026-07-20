################################################################################################################### 
##
## This script contains common/shared Virtual Administrator functions to dot source
## Version 1.0
##
###################################################################################################################

function Import-CustomerSettings {
    
    [CmdletBinding()]
    
    param(
        [Parameter(Mandatory)]
        [string]$SettingsPath,

        # Falls back to $env:VA_KEY_PATH when set, then the default below - lets the key
        # location be overridden per-machine/service-account without editing every caller.
        [string]$KeyPath = $(if ($env:VA_KEY_PATH) { $env:VA_KEY_PATH } else { "C:\PS\Settings\Key.txt" })
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

        $CustomerSettings = $JsonData | ConvertFrom-Json
        if (-not $CustomerSettings) { throw "Failed to parse JSON from $SettingsPath" }
        return $CustomerSettings
    
    }
    catch {
    
        throw "Import-CustomerSettings failed: $($_.Exception.Message)"
    
    }

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

function Ensure-Directory {
    
    param (
        [Parameter(Mandatory=$true)]
        [string]$Path
    )

    $Directory = Split-Path $Path -Parent
    if (-not (Test-Path $Directory)) {
        try {
            New-Item -ItemType Directory -Path $Directory -Force | Out-Null
            Write-Verbose "Created directory: $Directory"
        } catch {
            throw "Failed to create directory $Directory. Error: $_"
        }
    }
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
    }

}