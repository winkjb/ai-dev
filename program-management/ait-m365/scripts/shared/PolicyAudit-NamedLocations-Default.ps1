################################################################################################################### 
##
## This script conducts an audit of Entra Named Locations
## Version 2.5
##
###################################################################################################################

param(

    # Search and analysis variables

    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$Directory,
    [string]$CustomerFolder,
    
    # Output options

    [switch]$Logging,
    [string[]]$ToEmailAddr
    
)

# System settings and variables

$Date = Get-Date -Format yyyy-MM-dd
$CountLocations = 0
$CountResults = 0
$i = 0
$Results = @()

# Derived settings and variables

$BasePath = "C:\PS\$Directory"
$SettingsPath = Join-Path $BasePath "Settings\CustomerSettings.txt"
$LogFile = Join-Path $BasePath "Logs\EntraPolicyAudit-NamedLocations.csv"

# Start Processing

$StartTime = Get-Date

# Import functions

. "C:\PS\Scripts\VA-Functions.ps1"

# Import settings and acquire token

$CustomerSettings = Import-CustomerSettings -SettingsPath $SettingsPath
$Token = Get-GraphToken -CustomerSettings $CustomerSettings
$Headers = @{ Authorization = "Bearer $Token" }

# Get users and page results

$Uri = "https://graph.microsoft.com/v1.0/identity/conditionalAccess/namedLocations"
$Locations = Get-AllResults -Uri $Uri -Headers $Headers
$CountLocations = @($Locations).count

# Audit locations

$Results = foreach ($Location in $Locations){

    $i++

    Write-Progress -activity "Processing..." -status "$i out of $CountLocations completed" -PercentComplete ([int](($i/$CountLocations)*100))

    if ($Location.ipRanges) { 
        
        # Normalize finding
        
        [PSCustomObject][ordered] @{ 
            
            Date         = $Date
            DisplayName  = $Location.DisplayName
            CreatedDate  = $Location.CreatedDateTime
            IsTrusted    = $Location.IsTrusted
            Locations    = [string]::join(“;”, $Location.ipRanges.CidrAddress) 
        
        }
    
    } else { 
        
        # Normalize finding

        [PSCustomObject][ordered] @{ 
        
            Date         = $Date
            DisplayName  = $Location.DisplayName
            CreatedDate  = $Location.CreatedDateTime
            IsTrusted    = "N/A"
            Locations    = [string]::join(“;”, $Location.CountriesAndRegions) }
    
    }

    $CountResults ++ 

}

# End processing

$EndTime = Get-Date
$TotalTime = ($EndTime-$StartTime).TotalSeconds
$Minutes = "{0:N0}" -f ($TotalTime/60)
$Seconds = "{0:N0}" -f ($TotalTime%60)

Write-Host "`r`nAudit conducted on Entra tenant named locations in $Minutes minutes and $Seconds seconds.`r`n"

Write-Host "$CountResults locations audited."

# Log results

if ($Logging -eq $true) {

    if ($LogFile) {

        # Export log file

        Ensure-Directory ($LogFile)
        $Results | Sort-Object DisplayName | Export-CSV -Path $LogFile -NoTypeInformation 
        Write-Host "CSV File created at $LogFile.`r`n"

    }
    
    if ($ToEmailAddr) {

        # Email the CSV and stats to admin(s) 

        $Body = ""
    
        if ($Results) { $Body+= "CSV Attached for $Date<br>" } else { $Body+="No CSV Attached for $Date - No Results<br>" }

        $Body+="  
        Audit conducted on Entra ID named locations in $Minutes minutes and $Seconds seconds.<br>
        <br>
        $CountLocations locations audited.<br>
        <br>
        <br>
        ##############################<br>
        Source: Virtual Administrator<br>
        Customer Folder: $CustomerFolder<br>
        ##############################<br>
        "

        # Format the email parameters

        $SmtpServer  = $CustomerSettings.SmtpServer
        $Port        = $CustomerSettings.SmtpPort
        $From        = $CustomerSettings.SmtpFrom
        $To          = $ToEmailAddr
        $Subject     = "Entra Named Location Audit"
        $Body        = $Body
        $UseSsl      = $CustomerSettings.SmtpSsl -eq "Yes"

        if ($Results) { $Attachment = $LogFile } else { $Attachment = $null }
       
        if ( ($CustomerSettings.SmtpUsername -ne "") -and ($CustomerSettings.SmtpPassword -ne "") ) { 
    
            $SmtpPassword = ConvertTo-SecureString $CustomerSettings.SmtpPassword -AsPlainText -Force
            $Credentials = New-Object System.Management.Automation.PSCredential($CustomerSettings.SmtpUsername, $SmtpPassword)

        } else {

           $Credentials = $null 

        }

        # Send the email

        Send-Results -SmtpServer $SmtpServer -Port $Port -From $From -To $To -Subject $Subject -Body $Body -BodyAsHtml $true -UseSsl $UseSsl -Credential $Credentials -Attachment $Attachment

    }

}