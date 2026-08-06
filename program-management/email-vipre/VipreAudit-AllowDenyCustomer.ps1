################################################################################################################### 
##
## This script audits allow and deny lists in Vipre Email Security
## Version 1.1
##
## Search and analysis variables
$SettingsPath = "C:\PS\servit-msp\Settings\CustomerSettings.txt"
##
## Output options 
$Logging = $true # Set to $false to Disable Logging
$LogFile = "C:\PS\servit-msp\Logs\VipreAudit-AllowDenyCustomer.csv" # ie. c:\mylog.csv
$ToEmailAddr = @("bwinklesky@servit.net") # Multiple addr allowed but MUST be independent strings separated by comma
##
################################################################################################################### 

# System settings and variables

$Date = Get-Date -Format yyyy-MM-dd
$Epoch = Get-Date "1970-01-01 00:00:00"
$CountCustomers = 0
$CountIssues = 0
$StartApiResults = 1000
$ApiResults = 0
$StartApiOffset = 0
$ApiOffset = 0
$i = 1
$Customers = @()
$Domains = @()
$AllowList = @()
$DenyList = @()
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

$Uri = "https://portal.mailanyone.net/rest/public/customer/14432672/billing-summary"
$Headers = @{ 'Authorization' = $AuthResponse.session_id }
$ApiResponse = Invoke-RestMethod -Uri $Uri -Headers $Headers

# Page results

$Customers = $ApiResponse.customers
$CountCustomers = $Customers.count

# Audit customers

foreach ($Customer in $Customers) {

    Write-Progress -activity "Processing..." -status "$i out of $CountCustomers completed"
    
    $CustomerName = $Customer."customer_name"
        
    # Get customer domains
    
    $Uri = "https://portal.mailanyone.net/rest/public/customer/"+$Customer.customer_id+"/domain"
    $Headers = @{ 'Authorization' = $AuthResponse.session_id }
    $ApiResponse = Invoke-RestMethod -Uri $Uri -Headers $Headers
    
    # Page results

    $Domains = $ApiResponse.result.domain
       
    # Get allow lists

    $Uri = "https://portal.mailanyone.net/rest/public/customer/"+$Customer.customer_id+"/allowlist?num="+$StartApiResults
    $Headers = @{ 'Authorization' = $AuthResponse.session_id }
    $ApiResponse = Invoke-RestMethod -Uri $Uri -Headers $Headers
    
    # Page results
    
    $AllowList = $ApiResponse.result
    if ( $StartApiResults -lt $ApiResponse.total_rows ) {
        $ApiOffset = $StartApiResults
        $ApiResults = $ApiResponse.total_rows - $StartApiResults
        $Uri = "https://portal.mailanyone.net/rest/public/customer/"+$Customer.customer_id+"/allowlist?num="+$ApiResults+"&offset="+$ApiOffset
        $Headers = @{ 'Authorization' = $AuthResponse.session_id }
        $ApiResponse = Invoke-RestMethod -Uri $Uri -Headers $Headers
        $AllowList += $ApiResponse.result
    }

    # Get deny lists
    
    $Uri = "https://portal.mailanyone.net/rest/public/customer/"+$Customer.customer_id+"/denylist?num="+$StartApiResults
    $Headers = @{ 'Authorization' = $AuthResponse.session_id }
    $ApiResponse = Invoke-RestMethod -Uri $Uri -Headers $Headers
    
    # Page results
    
    $DenyList = $ApiResponse.result
    if ( $StartApiResults -lt $ApiResponse.total_rows ) {
        $ApiOffset = $StartApiResults
        $ApiResults = $ApiResponse.total_rows - $StartApiResults
        $Uri = "https://portal.mailanyone.net/rest/public/customer/"+$Customer.customer_id+"/denylist?num="+$ApiResults+"&offset="+$ApiOffset
        $Headers = @{ 'Authorization' = $AuthResponse.session_id }
        $ApiResponse = Invoke-RestMethod -Uri $Uri -Headers $Headers
        $DenyList += $ApiResponse.result
    }

    foreach ($Domain in $Domains){

        # Audit allow list for customer domain(s)/address(es)

        $Addresses = $AllowList | Where-Object { $_.value -eq $Domain }
        if($Addresses) { 
            foreach ($Address in $Addresses) {
                $UpdatedDate = ($Epoch.AddSeconds($Address.updated_on)).ToString("yyyy-MM-dd")
                $Results += New-Object PSObject -Property @{ Date=$Date; CustomerName=$CustomerName; Address=$Address.value; UpdatedDate=$UpdatedDate; Issue="Allow List - Customer Domain"; Action="Remove domain" }
                $CountIssues ++
            }
        }
        
        $Addresses = $AllowList | Where-Object { $_.value -like "*.$Domain" }
        if($Addresses) { 
            foreach ($Address in $Addresses) {
                $UpdatedDate = ($Epoch.AddSeconds($Address.updated_on)).ToString("yyyy-MM-dd")
                $Results += New-Object PSObject -Property @{ Date=$Date; CustomerName=$CustomerName; Address=$Address.value; UpdatedDate=$UpdatedDate; Issue="Allow List - Customer Subdomain"; Action="Remove domain" }
                $CountIssues ++
            }
        }

        $Addresses = $AllowList | Where-Object { $_.value -like "*@$Domain" } 
        if($Addresses) { 
            foreach ($Address in $Addresses) {
                $UpdatedDate = ($Epoch.AddSeconds($Address.updated_on)).ToString("yyyy-MM-dd")
                $Results += New-Object PSObject -Property @{ Date=$Date; CustomerName=$CustomerName; Address=$Address.value; UpdatedDate=$UpdatedDate; Issue="Allow List - Customer Address"; Action="Analyze address" }
                $CountIssues ++
            }
        }
        
        # Audit deny list for customer domain(s)/address(es)
        
        $Addresses = $DenyList | Where-Object { $_.value -eq $Domain }
        if($Addresses) { 
            foreach ($Address in $Addresses) {
                $UpdatedDate = ($Epoch.AddSeconds($Address.updated_on)).ToString("yyyy-MM-dd")
                $Results += New-Object PSObject -Property @{ Date=$Date; CustomerName=$CustomerName; Address=$Address.value; UpdatedDate=$UpdatedDate; Issue="Deny List - Customer Domain"; Action="Remove domain" }
                $CountIssues ++
            }
        }
        
        $Addresses = $DenyList | Where-Object { $_.value -like "*.$Domain" }
        if($Addresses) { 
            foreach ($Address in $Addresses) {
                $UpdatedDate = ($Epoch.AddSeconds($Address.updated_on)).ToString("yyyy-MM-dd")
                $Results += New-Object PSObject -Property @{ Date=$Date; CustomerName=$CustomerName; Address=$Address.value; UpdatedDate=$UpdatedDate; Issue="Deny List - Customer Subdomain"; Action="Remove domain" }
                $CountIssues ++
            }
        }
        
        $Addresses = $DenyList | Where-Object { $_.value -like "*@$Domain" } 
        if($Addresses) {  
            foreach ($Address in $Addresses) {
                $UpdatedDate = ($Epoch.AddSeconds($Address.updated_on)).ToString("yyyy-MM-dd")
                $Results += New-Object PSObject -Property @{ Date=$Date; CustomerName=$CustomerName; Address=$Address.value; UpdatedDate=$UpdatedDate; Issue="Deny List - Customer Address"; Action="Remove address" }
                $CountIssues ++
            }
        }
        
    }
    
    # Audit allowed list for popular domain(s)/address(es)
    
    $Addresses = $AllowList | Where-Object { ($_.value -eq "*@gmail.com") -or ($_.value -eq "@gmail.com") -or ($_.value -eq "gmail.com") }
    if($Addresses) { 
        foreach ($Address in $Addresses) {
            $UpdatedDate = ($Epoch.AddSeconds($Address.updated_on)).ToString("yyyy-MM-dd")
            $Results += New-Object PSObject -Property @{ Date=$Date; CustomerName=$CustomerName; Address=$Address.value; UpdatedDate=$UpdatedDate; Issue="Allow List - Gmail Domain"; Action="Remove domain" }
            $CountIssues ++
        }
    }

    $Addresses = $AllowList | Where-Object { ($_.value -eq "*@amazonses.com") -or ($_.value -eq "@amazonses.com") -or ($_.value -eq "amazonses.com") -or ($_.value -like "@*amazonses.com") -or ($_.value -like "us*amazonses.com") }
    if($Addresses) { 
        foreach ($Address in $Addresses) {
            $UpdatedDate = ($Epoch.AddSeconds($Address.updated_on)).ToString("yyyy-MM-dd")
            $Results += New-Object PSObject -Property @{ Date=$Date; CustomerName=$CustomerName; Address=$Address.value; UpdatedDate=$UpdatedDate; Issue="Allow List - Amazon SES Domain"; Action="Remove domain" }
            $CountIssues ++
        }
    }

    # Audit deny list for Vipre domain(s)/address(es)
    
    $Addresses = $DenyList | Where-Object { $_.value -like "*mailanyone.net" }
    if($Addresses) { 
        foreach ($Address in $Addresses) {
            $UpdatedDate = ($Epoch.AddSeconds($Address.updated_on)).ToString("yyyy-MM-dd")
            $Results += New-Object PSObject -Property @{ Date=$Date; CustomerName=$CustomerName; Address=$Address.value; UpdatedDate=$UpdatedDate; Issue="Deny List - Vipre Domain"; Action="Remove domain" }
            $CountIssues ++
        }
    }
    
    # Audit deny list for popular domain(s)/address(es)
    
    $Addresses = $DenyList | Where-Object { ($_.value -eq "*@gmail.com") -or ($_.value -eq "@gmail.com") -or ($_.value -eq "gmail.com") }
    if($Addresses) { 
        foreach ($Address in $Addresses) {
            $UpdatedDate = ($Epoch.AddSeconds($Address.updated_on)).ToString("yyyy-MM-dd")
            $Results += New-Object PSObject -Property @{ Date=$Date; CustomerName=$CustomerName; Address=$Address.value; UpdatedDate=$UpdatedDate; Issue="Deny List - Gmail Domain"; Action="Remove domain" }
            $CountIssues ++
        }
    }

    $Addresses = $DenyList | Where-Object { ($_.value -eq "*@amazonses.com") -or ($_.value -eq "@amazonses.com") -or ($_.value -eq "amazonses.com") -or ($_.value -like "@*amazonses.com") -or ($_.value -like "us*amazonses.com") }
    if($Addresses) { 
        foreach ($Address in $Addresses) {
            $UpdatedDate = ($Epoch.AddSeconds($Address.updated_on)).ToString("yyyy-MM-dd")
            $Results += New-Object PSObject -Property @{ Date=$Date; CustomerName=$CustomerName; Address=$Address.value; UpdatedDate=$UpdatedDate; Issue="Deny List - Amazon SES Domain"; Action="Remove domain" }
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

Write-Host "$CountCustomers customer(s) audited.`r`n"
Write-Host "$CountIssues issue(s) identified."

# Log results

if ($Logging -eq $true) {

    # Export log file

    Write-Host "CSV File created at $LogFile.`r`n"
    $Results | Select Date,CustomerName,Address,UpdatedDate,Issue,Action | Sort CustomerName,Issue,Address | Export-CSV -Path $LogFile -NoTypeInformation 
    
    # Email the CSV and stats to admin(s) 

    $Body = ""
    
    if ($Results) { $Body+= "CSV Attached for $Date<br>" } else { $Body+="No CSV Attached for $Date - No Results<br>" }

    $Body+="    
    Audit conducted on Vipre allow/deny lists in $Minutes minutes and $Seconds seconds.<br>
    <br>
    $CountCustomers customer(s) audited.<br>
    $CountIssues issue(s) identified.
    "

    # Format the email parameters

    $SmtpServer  = $CustomerSettings.SmtpServer
    $Port        = $CustomerSettings.SmtpPort
    $From        = $CustomerSettings.SmtpFrom
    $To          = $ToEmailAddr
    $Subject     = "Vipre Customer Audit - Allow/Deny Lists"
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