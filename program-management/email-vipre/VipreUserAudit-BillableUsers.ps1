################################################################################################################### 
##
## This script audits billable users in Vipre Email Security
## Version 1.3
##
## Search and analysis variables
$SettingsPath = "C:\PS\servit-msp\Settings\CustomerSettings.txt"
##
## Output options 
$Logging = $true # Set to $false to Disable Logging
$LogFile = "C:\PS\servit-msp\Logs\VipreUserAudit-BillableUsers.csv" # ie. c:\mylog.csv
$ToEmailAddr = @("bwinklesky@servit.net","tmarsili@servit.net","chart@servit.net") # Multiple addr allowed but MUST be independent strings separated by comma
##
################################################################################################################### 

# System settings and variables

$Date = Get-Date -Format yyyy-MM-dd
$Epoch = Get-Date "1970-01-01 00:00:00"
$CountCustomers = 0
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

# Create a hashtable for the token request and acquire token

$Params = @{
	'Uri' = "https://portal.mailanyone.net/rest/public/login"
	'Method' = 'Post'
    'Body' = @{
        'username' = $CustomerSettings.VipreUsername
        'password' = $CustomerSettings.ViprePassword
    }
    'ContentType' = 'application/x-www-form-urlencoded'
}
$AuthResponse = Invoke-RestMethod @Params

# Get customers

$Uri = "https://portal.mailanyone.net/rest/public/customer/"+$CustomerSettings.VipreAccountId+"/billing-summary"
$Headers = @{ 'Authorization' = $AuthResponse.session_id }
$ApiResponse = Invoke-RestMethod -Uri $Uri -Headers $Headers

# Page results

$Customers = $ApiResponse.customers

# Audit customers

foreach ($Customer in $Customers) {

    $CustomerName = $Customer."customer_name"
    
    if ($CustomerName -like "ServIT*") { continue }

    $CreatedDate = ($Epoch.AddSeconds($Customer."customer_created_date")).ToString("yyyy-MM-dd")
    $Package = [string]::join(", ",$Customer.packages."current_name")
    $BillableUsers = [string]::join(", ",$Customer.packages.billable)

    $Results += New-Object PSObject -Property @{ Date=$Date; CustomerName = $CustomerName; Package = $Package; BillableUsers = $BillableUsers; CreatedDate = $CreatedDate }

    $CountCustomers ++
}

# End processing

$EndTime = Get-Date
$TotalTime = ($EndTime-$StartTime).TotalSeconds
$Minutes = "{0:N0}" -f ($TotalTime/60)
$Seconds = "{0:N0}" -f ($TotalTime%60)

Write-Host "`r`nAudit conducted on Vipre customers in $Minutes minutes and $Seconds seconds.`r`n"

Write-Host "$CountCustomers customer(s) identified."

# Log results

if ($Logging -eq $true) {

    # Export log file

    Write-Host "CSV File created at $LogFile.`r`n"
    $Results | Select Date,CustomerName,Package,BillableUsers,CreatedDate | Sort CustomerName | Export-CSV -Path $LogFile -NoTypeInformation 
    
    # Email the CSV and stats to admin(s) 

    $Body = ""
    
    if ($Results) { $Body+= "CSV Attached for $Date<br>" } else { $Body+="No CSV Attached for $Date - No Results<br>" }

    $Body+="    
    Audit conducted on Vipre customer(s) in $Minutes minutes and $Seconds seconds.<br>
    <br>
    $CountCustomers customer(s) identified.
    "

    # Format the email parameters

    $SmtpServer  = $CustomerSettings.SmtpServer
    $Port        = $CustomerSettings.SmtpPort
    $From        = $CustomerSettings.SmtpFrom
    $To          = $ToEmailAddr
    $Subject     = "Vipre Customer Audit - Billable Users"
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