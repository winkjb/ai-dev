################################################################################################################### 
##
## This script audits billable users in Proofpoint Essentials Email Security
## Version 1.2
##
## Search and analysis variables
$SettingsPath = "C:\PS\servit-msp\Settings\CustomerSettings.txt"
##
## Output options 
$Logging = $true # Set to $false to Disable Logging
$LogFile = "C:\PS\servit-msp\Logs\ProofpointUserAudit-BillableUsers.csv" # ie. c:\mylog.csv
$ToEmailAddr = @("bwinklesky@servit.net","tmarsili@servit.net","chart@servit.net") # Multiple addr allowed but MUST be independent strings separated by comma
##
################################################################################################################### 

# System settings and variables

$Date = Get-Date -Format yyyy-MM-dd
$CountCustomers = 0
$i = 0
$CountResults = 0
$Customers = @()
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
        'X-Password' = $CustomerSettings.ProofpointPassword
    }
$ApiResponse = Invoke-RestMethod -Uri $Uri -Headers $Headers

# Page results

$Customers = $ApiResponse.orgs
$CountCustomers = $Customers.count

# Audit customers

foreach ($Customer in $Customers) {

    $i++

    Write-Progress -activity "Processing..." -status "$i out of $CountCustomers customers completed" -PercentComplete ([int](($i/$CountCustomers)*100))
    
    if ($Customer.name -like "ServIT*") { continue }
    
    $CustomerName = $Customer.name
    $Package = $Customer.licensing_package
    $BillableUsers = $Customer.active_users

    $Results += [PSCustomObject][ordered] @{ Date=$Date; CustomerName = $CustomerName; Package = $Package; BillableUsers = $BillableUsers }

    $CountResults++

}

# End processing

$EndTime = Get-Date
$TotalTime = ($EndTime-$StartTime).TotalSeconds
$Minutes = "{0:N0}" -f ($TotalTime/60)
$Seconds = "{0:N0}" -f ($TotalTime%60)

Write-Host "`r`nAudit conducted on Proofpoint customers in $Minutes minutes and $Seconds seconds.`r`n"

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
    Audit conducted on Proofpoint customer(s) in $Minutes minutes and $Seconds seconds.<br>
    <br>
    $CountCustomers customer(s) identified.
    "

    # Format the email parameters

    $SmtpServer  = $CustomerSettings.SmtpServer
    $Port        = $CustomerSettings.SmtpPort
    $From        = $CustomerSettings.SmtpFrom
    $To          = $ToEmailAddr
    $Subject     = "Proofpoint Customer Audit - Billable Users"
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