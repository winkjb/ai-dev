################################################################################################################### 
##
## This script audits customers' mailflow in Proofpoint Essentials Email Security
## Version 1.2
##
## Search and analysis variables
$SettingsPath = "C:\PS\servit-msp\Settings\CustomerSettings.txt"
$ExcludedCustomers = @()
$LogExclusions = $false # Set to $false to only capture issues
##
## Output options 
$Logging = $true # Set to $false to Disable Logging
$LogFile = "C:\PS\servit-msp\Logs\ProofpointAudit-Reporting.csv" # ie. c:\mylog.csv
$ToEmailAddr = @("bwinklesky@servit.net") # Multiple addr allowed but MUST be independent strings separated by comma
##
################################################################################################################### 

# System settings and variables

$Date = Get-Date -Format yyyy-MM-dd
$CountCustomers = 0
$CountExclusions = 0
$CountResults = 0
$i = 0
$Customers = @()
$CustomerReport = @()
$Results = @()

# Import functions

. "C:\PS\Scripts\VA-Functions.ps1"

# Start processing

$StartTime = Get-Date

# Import settings

$Key = Get-Content "C:\PS\Settings\Key.txt"
[System.Array]::Reverse($Key)
$SecureString = Get-Content $SettingsPath | ConvertTo-SecureString -Key $Key
$JsonData = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString))
$CustomerSettings = $JsonData | ConvertFrom-Json

# Get customers

$Uri = "https://us2.proofpointessentials.com/api/v1/orgs/servit.net/orgs"
$Headers = @{
        'X-User' = $CustomerSettings.ProofpointUsername
        'X-Password' = $CustomerSettings.ProofpointPassword }
$ApiResponse = Invoke-RestMethod -Uri $Uri -Headers $Headers

# Page results

$Customers = $ApiResponse.orgs 
$CountCustomers = $Customers.count

# Audit customers

foreach ($Customer in $Customers) {

    $i ++

    Write-Progress -activity "Processing..." -status "$i out of $CountCustomers customers completed" -PercentComplete ([int](($i/$CountCustomers)*100))
    
    if ($Customer.name -eq "ServIT MSP") { $CountExclusions++; continue } 

     # Get customer reports

    $Uri = "https://us2.proofpointessentials.com/api/v1/reporting/"+$Customer.primary_domain+"/monthly"
    $CustomerReport = Invoke-RestMethod -Uri $Uri -Headers $Headers
    
    # Audit customers

    $InboundAttachmentsDefended = $CustomerReport.inbound.attachment_defended_total
    $InboundBlacklist = $CustomerReport.inbound.blacklist_total
    $InboundClean = $CustomerReport.inbound.clean_total
    $InboundImageBlocked = $CustomerReport.inbound.image_blocked_total
    $InboundSpam = $CustomerReport.inbound.spam_total
    $InboundVirus = $CustomerReport.inbound.virus_total
    $InboundFraud = $CustomerReport.inbound.fraud_total
    $InboundWhitelist = $CustomerReport.inbound.whitelist_total
    $TotalInboundMessages = $InboundAttachmentsDefended + $InboundBlacklist + $InboundClean + $InboundImageBlocked + $InboundSpam + $InboundVirus + $InboundFraud + $InboundWhitelist
    
    $OutboundAttachmentsDefended = $CustomerReport.outbound.attachment_defended_total
    $OutboundBlacklist = $CustomerReport.outbound.blacklist_total
    $OutboundClean = $CustomerReport.outbound.clean_total
    $OutboundImageBlocked = $CustomerReport.outbound.image_blocked_total
    $OutboundSpam = $CustomerReport.outbound.spam_total
    $OutboundVirus = $CustomerReport.outbound.virus_total
    $OutboundFraud = $CustomerReport.outbound.fraud_total
    $OutboundWhitelist = $CustomerReport.outbound.whitelist_total
    $TotalOutboundMessages = $OutboundAttachmentsDefended + $OutboundBlacklist + $OutboundClean + $OutboundImageBlocked + $OutboundSpam + $OutboundVirus + $OutboundFraud + $OutboundWhitelist
        
    if ($ExcludedCustomers -contains $Customer.name) {

        $CountExclusions++
        if ($LogExclusions -eq $true) { 
        
            $Results += [PSCustomObject][ordered] @{ Date=$Date; CustomerName=$Customer.name; TotalInboundMessages=$TotalInboundMessages; InboundAttachmentsDefended=$InboundAttachmentsDefended; InboundBlacklist=$InboundBlacklist; InboundClean=$InboundClean; InboundImageBlocked=$InboundImageBlocked; InboundSpam=$InboundSpam; InboundVirus=$InboundVirus; InboundFraud=$InboundFraud; InboundWhitelist=$InboundWhitelist; TotalOutboundMessages=$TotalOutboundMessages; OutboundAttachmentsDefended=$OutboundAttachmentsDefended; OutboundBlacklist=$OutboundBlacklist; OutboundClean=$OutboundClean; OutboundImageBlocked=$OutboundImageBlocked; OutboundSpam=$OutboundSpam; OutboundVirus=$OutboundVirus; OutboundFraud=$OutboundFraud; OutboundWhitelist=$OutboundWhitelist; InExclusionGroup="Y" }
            $CountResults++

        }

    } else {
                
        $Results += [PSCustomObject][ordered] @{ Date=$Date; CustomerName=$Customer.name; TotalInboundMessages=$TotalInboundMessages; InboundAttachmentsDefended=$InboundAttachmentsDefended; InboundBlacklist=$InboundBlacklist; InboundClean=$InboundClean; InboundImageBlocked=$InboundImageBlocked; InboundSpam=$InboundSpam; InboundVirus=$InboundVirus; InboundFraud=$InboundFraud; InboundWhitelist=$InboundWhitelist; TotalOutboundMessages=$TotalOutboundMessages; OutboundAttachmentsDefended=$OutboundAttachmentsDefended; OutboundBlacklist=$OutboundBlacklist; OutboundClean=$OutboundClean; OutboundImageBlocked=$OutboundImageBlocked; OutboundSpam=$OutboundSpam; OutboundVirus=$OutboundVirus; OutboundFraud=$OutboundFraud; OutboundWhitelist=$OutboundWhitelist; InExclusionGroup="N" }
        $CountResults++

    }
   
    

}

# End processing

$EndTime = Get-Date
$TotalTime = ($EndTime-$StartTime).TotalSeconds
$Minutes = "{0:N0}" -f ($TotalTime/60)
$Seconds = "{0:N0}" -f ($TotalTime%60)

Write-Host "`r`nAudit conducted on Proofpoint reporting in $Minutes minutes and $Seconds seconds.`r`n"

Write-Host "$i customer(s) audited."
Write-Host "$CountExclusions customer(s) in exclusion groups."
Write-Host "$CountResults customer(s) identified."

# Log results

if ($Logging -eq $true) {

    # Export log file

    Write-Host "CSV File created at $LogFile.`r`n"
    $Results | Sort CustomerName | Export-CSV -Path $LogFile -NoTypeInformation 
    
    # Email the CSV and stats to admin(s) 

    $Body = ""
    
    if ($Results) { $Body+= "CSV Attached for $Date<br>" } else { $Body+="No CSV Attached for $Date - No Results<br>" }

    $Body+="   
    Audit conducted on Proofpoint mailflow in $Minutes minutes and $Seconds seconds.<br>
    <br>
    $i customer(s) audited.<br>
    $CountExclusions customer(s) in exclusion groups.<br>
    $CountResults customer(s) identified.
    "
    
    # Format the email parameters

    $SmtpServer  = $CustomerSettings.SmtpServer
    $Port        = $CustomerSettings.SmtpPort
    $From        = $CustomerSettings.SmtpFrom
    $To          = $ToEmailAddr
    $Subject     = "Proofpoint Audit - Monthly Mailflow Reporting"
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