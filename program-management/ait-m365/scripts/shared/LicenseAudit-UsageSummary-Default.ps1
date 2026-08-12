################################################################################################################### 
##
## This script audits M365 license usage
## Version 2.5
##
################################################################################################################### 

param(

    # Search and analysis variables

    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$Directory,
    [string]$CustomerFolder,
    [string[]]$ExcludedLicenses,
    [switch]$LogExclusions,
   
    # Output options

    [switch]$Logging,
    [string[]]$ToEmailAddr
    
)

# System settings and variables

$Date = Get-Date -Format yyyy-MM-dd
$CountLicenses = 0
$ConsumedLicenses = 0
$MaxLicenses = 0
$UnusedLicenses = 0
$PercentageUsed = 0
$CountExclusions = 0
$CountResults = 0
$i = 0
$Results = @()

# Derived settings and variables

$BasePath = "C:\PS\$Directory"
$SettingsPath = Join-Path $BasePath "Settings\CustomerSettings.txt"
$LogFile = Join-Path $BasePath "Logs\EntraLicenseAudit-UsageSummary.csv"

# Import functions

. "C:\PS\Scripts\VA-Functions.ps1"

# Start processing

$StartTime = Get-Date

# Import settings and acquire token

$CustomerSettings = Import-CustomerSettings -SettingsPath $SettingsPath
$Token = Get-GraphToken -CustomerSettings $CustomerSettings
$Headers = @{ Authorization = "Bearer $Token" }

# Get licenses and page results

$Uri = "https://graph.microsoft.com/v1.0/subscribedSkus"
$Licenses = Get-AllResults -Uri $Uri -Headers $Headers
$CountLicenses = @($Licenses).count

# Audit licenses 

$Results = foreach ($License in $Licenses) {

    $i++

    Write-Progress -activity "Processing..." -status "$i out of $CountLicenses completed" -PercentComplete ([int](($i/$CountLicenses)*100))

    # Get license usage

    $UserLicense = Get-FriendlyLicenseName -sku $License.skuPartNumber
    $ConsumedLicenses = $License.consumedUnits 
    $MaxLicenses = $License.prepaidUnits.enabled
    $UnusedLicenses = $MaxLicenses - $ConsumedLicenses
    if ($MaxLicenses -eq 0) { $PercentageUsed = 0 } else { $PercentageUsed = [math]::Round($ConsumedLicenses / $MaxLicenses,2) * 100 }

    # Identify exclusions

    $InExclusion = $ExcludedLicenses -contains $License.skuPartNumber
    
    if ($InExclusion) { $CountExclusions++ }

    # Log finding

    if (-not $InExclusion -or $LogExclusions) {

        # Normalize finding

        $Finding = [ordered] @{ 
        
            Date              = $Date
            UserLicense       = $UserLicense
            ConsumedLicenses  = $ConsumedLicenses
            MaxLicenses       = $MaxLicenses
            UnusedLicenses    = $UnusedLicenses
            PercentageUsed    = $PercentageUsed
            
        }

        if ($LogExclusions) { $Finding.InExclusionGroup = if ($InExclusion) {"Y"} else {$null} }

        [PSCustomObject]$Finding

    $CountResults++

    }      

}

# End processing

$EndTime = Get-Date
$TotalTime = ($EndTime-$StartTime).TotalSeconds
$Minutes = "{0:N0}" -f ($TotalTime/60)
$Seconds = "{0:N0}" -f ($TotalTime%60)

Write-Host "`r`nAudit conducted on Entra licenses in $Minutes minutes and $Seconds seconds.`r`n"

Write-Host "$CountLicenses license(s) audited."
Write-Host "$CountExclusions license(s) excluded."
Write-Host "$CountResults license(s) identified."

# Log results

if ($Logging -eq $true) {

    if ($LogFile) { 

        # Export log file

        Ensure-Directory ($LogFile)
        $Results | Sort-Object UserLicense | Export-CSV -Path $LogFile -NoTypeInformation 
        Write-Host "CSV File created at $LogFile.`r`n"
    
    }

    if ($ToEmailAddr) {

        # Email the CSV and stats to admin(s)

        $Body=""

        if ($Results) { $Body+= "CSV Attached for $Date<br>" } else { $Body+="No CSV Attached for $Date - No Results<br>" }

        $Body+="

        Audit conducted on Entra licenses in $Minutes minutes and $Seconds seconds.<br>
        <br>
        $CountLicenses license(s) audited.<br>
        $CountExclusions license(s) excluded.<br>
        $CountResults license(s) identified.<br>
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
        $Subject     = "Entra License Audit - Summary"
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