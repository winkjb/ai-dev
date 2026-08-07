################################################################################################################### 
##
## This script audits customer admin users in Vipre Email Security
## Version 1.2
##
## Search and analysis variables
$SettingsPath = "C:\PS\servit-msp\Settings\CustomerSettings.txt"
$ExcludedAdmins = @()
$EnabledOnly = $false # Set to $true to only capture enabled admins
$LogExclusions = $false # Set to $false to only capture issues
##
## Output options 
$Logging = $true # Set to $false to Disable Logging
$LogFile = "C:\PS\servit-msp\Logs\VipreAdminAudit-Customers.csv" # ie. c:\mylog.csv
$ToEmailAddr = @("bwinklesky@servit.net") # Multiple addr allowed but MUST be independent strings separated by comma
##
################################################################################################################### 

# System settings and variables

$Date = Get-Date -Format yyyy-MM-dd
$Epoch = Get-Date "1970-01-01 00:00:00"
$CountCustomers = 0
$CountAdmins = 0
$CountExclusions = 0
$CountResults = 0
$i = 1
$Customers = @()
$Admins = @()
$Results = @()

# Import functions

. "C:\PS\Scripts\VA-Functions.ps1"
. (Join-Path $PSScriptRoot "..\..\scripts\Functions-VA-Common.ps1")

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

# Audit customer admins

foreach ($Customer in $Customers) {

    Write-Progress -activity "Processing..." -status "$i out of $CountCustomers customers completed"
    
    $CustomerName = $Customer.customer_name
    
    # Get customer admins

    $Uri = "https://portal.mailanyone.net/rest/public/customer/"+$Customer.customer_id+"/admin?num=1000&offset=0"
    $Headers = @{ 'Authorization' = $AuthResponse.session_id }
    $ApiResponse = Invoke-RestMethod -Uri $Uri -Headers $Headers
    
    # Filter admins

    if ($EnabledOnly -eq $false) { 
        $Admins = $ApiResponse.result 
    } else { 
        $Admins = $ApiResponse.result | Where-Object { $_.is_active -eq $true } }
    $CountAdmins += $Admins.count

    # Audit admins

    foreach ($Admin in $Admins) {

        $LastLogin = ($Epoch.AddSeconds($Admin.last_login_time)).ToString("yyyy-MM-dd")
        $DaysAgo = Get-DaysSince -Value $Admin.last_login_time -Epoch

        # Compare $Admins to excluded sites

        if ($ExcludedAdmins -contains $Admin.box_fulladdress) {

            $CountExclusions ++
            if ($LogExclusions -eq $true) { $Results += New-Object PSObject -Property @{ Date=$Date; CustomerName=$CustomerName; FirstName=$Admin.first_name; LastName=$Admin.last_name; Username=$Admin.box_fulladdress; Role=$Admin.role_name; LastLogin=$LastLogin; DaysAgo=$DaysAgo; Enabled=$Admin.is_active; InExclusionGroup="Y" }}

        } else {

            $Results += New-Object PSObject -Property @{ Date=$Date; CustomerName=$CustomerName; FirstName=$Admin.first_name; LastName=$Admin.last_name; Username=$Admin.box_fulladdress; Role=$Admin.role_name; LastLogin=$LastLogin; DaysAgo=$DaysAgo; Enabled=$Admin.is_active; InExclusionGroup="N" }
            $CountResults ++

        }
          
    }

    $i ++

}

# End processing

$EndTime = Get-Date
$TotalTime = ($EndTime-$StartTime).TotalSeconds
$Minutes = "{0:N0}" -f ($TotalTime/60)
$Seconds = "{0:N0}" -f ($TotalTime%60)

Write-Host "`r`nAudit conducted on Vipre admins in $Minutes minutes and $Seconds seconds.`r`n"

Write-Host "$CountCustomers customer(s) audited."
Write-Host "$CountAdmins admin(s) audited."
Write-Host "$CountExclusions admin(s) in exclusion groups."
Write-Host "$CountResults admin(s) identified."

# Log results

if ($Logging -eq $true) {

    # Export log file

    Write-Host "CSV File created at $LogFile.`r`n"
    $Results | Select Date,CustomerName,FirstName,LastName,Username,Role,LastLogin,DaysAgo,Enabled | Sort CustomerName,Role,FirstName | Export-CSV -Path $LogFile -NoTypeInformation
    
    # Email the CSV and stats to admin(s) 

    $Body = ""
    
    if ($Results) { $Body+= "CSV Attached for $Date<br>" } else { $Body+="No CSV Attached for $Date - No Results<br>" }

    $Body+="    
    Audit conducted on Vipre admins in $Minutes minutes and $Seconds seconds.<br>
    <br>
    $CountAdmins admin(s) audited.<br>
    $CountExclusions admin(s) in exclusion groups.<br>
    $CountResults admin(s) identified.
    "

    # Format the email parameters

    $SmtpServer  = $CustomerSettings.SmtpServer
    $Port        = $CustomerSettings.SmtpPort
    $From        = $CustomerSettings.SmtpFrom
    $To          = $ToEmailAddr
    $Subject     = "Vipre Admin Audit - Customers"
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