################################################################################################################### 
##
## This script audits user sync status in Vipre Email Security
## Version 1.1
##
## Search and analysis variables
$SettingsPath = "C:\PS\servit-msp\Settings\CustomerSettings.txt"
##
## Output options 
$Logging = $true # Set to $false to Disable Logging
$LogFile = "C:\PS\servit-msp\Logs\VipreUserAudit-AzureSync.csv" # ie. c:\mylog.csv
$ToEmailAddr = @("bwinklesky@servit.net") # Multiple addr allowed but MUST be independent strings separated by comma
##
################################################################################################################### 

# System settings and variables

$Date = Get-Date -Format yyyy-MM-dd
$CountCustomers = 0
$CountAzure = 0
$CountIssues = 0
$StartApiResults = 1000
$ApiResults = 0
$StartApiOffset = 0
$ApiOffset = 0
$i = 1
$Mailboxes = @()
$Addresses = @()
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
$CountCustomers = $Customers.count

# Audit customers

foreach ($Customer in $Customers) {

    Write-Progress -activity "Processing..." -status "$i out of $CountCustomers customers completed"
    
    $CustomerName = $Customer.customer_name
        
    # Get customer mailboxes
        
    $Uri = "https://portal.mailanyone.net/rest/public/customer/"+$Customer.customer_id+"/mailbox?num="+$StartApiResults
    $Headers = @{ 'Authorization' = $AuthResponse.session_id }
    $ApiResponse = Invoke-RestMethod -Uri $Uri -Headers $Headers

    # Page results
    
    $Mailboxes = $ApiResponse.result
    if ( $StartApiResults -lt $ApiResponse.total_rows ) {
        $ApiOffset = $StartApiResults
        $ApiResults = $ApiResponse.total_rows - $StartApiResults
        $Uri = "https://portal.mailanyone.net/rest/public/customer/"+$Customer.customer_id+"/mailbox?num="+$ApiResults+"&offset="+$ApiOffset
        $Headers = @{ 'Authorization' = $AuthResponse.session_id }
        $ApiResponse = Invoke-RestMethod -Uri $Uri -Headers $Headers
        $Mailboxes += $ApiResponse.result
    }
    
    # Confirm/deny if customer is AzureAD synced

    if ( $Mailboxes | Where-Object { $_.source -eq "Azure" } ) { 
    
        $CountAzure ++
        $Addresses = $Mailboxes | Where-Object { $_.source -ne "Azure" }
        foreach ($Address in $Addresses) { 
            $Results += New-Object PSObject -Property @{ Date=$Date; CustomerName=$CustomerName; Address=$Address.mailbox_address; Source=$Address.source; Issue="Azure Customer - User not synced"; Action="Remove user" }
            $CountIssues ++
        }
    
    }

    $i ++

}

# End processing

$EndTime = Get-Date
$TotalTime = ($EndTime-$StartTime).TotalSeconds
$Minutes = "{0:N0}" -f ($TotalTime/60)
$Seconds = "{0:N0}" -f ($TotalTime%60)

Write-Host "`r`nAudit conducted on Vipre allow/deny lists in $Minutes minutes and $Seconds seconds.`r`n"

Write-Host "$CountCustomers customer(s) audited."
Write-Host "$CountAzure customer(s) Azure AD synced."
Write-Host "$CountIssues issue(s) identified."

# Log results

if ($Logging -eq $true) {

    # Export log file

    Write-Host "CSV File created at $LogFile.`r`n"
    $Results | Select Date,CustomerName,Address,Source,Issue,Action | Sort CustomerName,Issue,Address | Export-CSV -Path $LogFile -NoTypeInformation 
    
    # Email the CSV and stats to admin(s) 

    $Body = ""
    
    if ($Results) { $Body+= "CSV Attached for $Date<br>" } else { $Body+="No CSV Attached for $Date - No Results<br>" }

    $Body+="    
    Audit conducted on Vipre allow/deny lists in $Minutes minutes and $Seconds seconds.<br>
    <br>
    $CountCustomers customer(s) audited.<br>
    $CountAzure customer(s) Azure AD synced.<br>
    $CountIssues issue(s) identified.
    "

    # Format the email parameters

    $SmtpServer  = $CustomerSettings.SmtpServer
    $Port        = $CustomerSettings.SmtpPort
    $From        = $CustomerSettings.SmtpFrom
    $To          = $ToEmailAddr
    $Subject     = "Vipre User Audit - Azure Sync"
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