################################################################################################################### 
##
## This script audits allow and deny lists in Proofpoint Essentials Email Security
## Version 1.2
##
## Search and analysis variables
$SettingsPath = "C:\PS\servit-msp\Settings\CustomerSettings.txt"
##
## Output options 
$Logging = $true # Set to $false to Disable Logging
$LogFile = "C:\PS\servit-msp\Logs\ProofpointAudit-AllowDenyCustomer.csv" # ie. c:\mylog.csv
$ToEmailAddr = @("bwinklesky@servit.net") # Multiple addr allowed but MUST be independent strings separated by comma
##
################################################################################################################### 

# System settings and variables

$Date = Get-Date -Format yyyy-MM-dd
$CountCustomers = 0
$CountIssues = 0
$i = 0
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

    $i++

    Write-Progress -activity "Processing..." -status "$i out of $CountCustomers completed" -PercentComplete ([int](($i/$CountCustomers)*100))
    
    $CustomerName = $Customer.name
        
    # Get customer domains
  
    $Domains = $Customer.domains | Where-Object { ($_.is_relay -eq $true -and $_.is_active -eq $true) } | Select name -ExpandProperty name

    # Get allow lists

    $AllowList = $Customer.white_list_senders

    # Get deny lists
    
    $DenyList = $Customer.black_list_senders
    
    foreach ($Domain in $Domains){

        # Audit allow list for customer domain(s)/address(es)

        $Addresses = $AllowList | Where-Object { $_ -eq $Domain }
        if($Addresses) { 
            foreach ($Address in $Addresses) {
                $Results += [PSCustomObject][ordered] @{ Date=$Date; CustomerName=$CustomerName; Address=$Address; Issue="Allow List - Customer Domain"; Action="Remove domain" }
                $CountIssues ++
            }
        }
        
        $Addresses = $AllowList | Where-Object { $_ -like "*.$Domain" }
        if($Addresses) { 
            foreach ($Address in $Addresses) {
                $Results += [PSCustomObject][ordered] @{ Date=$Date; CustomerName=$CustomerName; Address=$Address; Issue="Allow List - Customer Subdomain"; Action="Remove domain" }
                $CountIssues ++
            }
        }

        $Addresses = $AllowList | Where-Object { $_ -like "*@$Domain" } 
        if($Addresses) { 
            foreach ($Address in $Addresses) {
                $Results += [PSCustomObject][ordered] @{ Date=$Date; CustomerName=$CustomerName; Address=$Address; Issue="Allow List - Customer Address"; Action="Analyze address" }
                $CountIssues ++
            }
        }
        
        # Audit deny list for customer domain(s)/address(es)
        
        $Addresses = $DenyList | Where-Object { $_ -eq $Domain }
        if($Addresses) { 
            foreach ($Address in $Addresses) {
                $Results += [PSCustomObject][ordered] @{ Date=$Date; CustomerName=$CustomerName; Address=$Address; Issue="Deny List - Customer Domain"; Action="Remove domain" }
                $CountIssues ++
            }
        }
        
        $Addresses = $DenyList | Where-Object { $_ -like "*.$Domain" }
        if($Addresses) { 
            foreach ($Address in $Addresses) {
                $Results += [PSCustomObject][ordered] @{ Date=$Date; CustomerName=$CustomerName; Address=$Address; Issue="Deny List - Customer Subdomain"; Action="Remove domain" }
                $CountIssues ++
            }
        }
        
        $Addresses = $DenyList | Where-Object { $_ -like "*@$Domain" } 
        if($Addresses) {  
            foreach ($Address in $Addresses) {
                $Results += [PSCustomObject][ordered] @{ Date=$Date; CustomerName=$CustomerName; Address=$Address; Issue="Deny List - Customer Address"; Action="Remove address" }
                $CountIssues ++
            }
        }
        
    }
    
    # Audit allowed list for popular domain(s)/address(es)
    
    $Addresses = $AllowList | Where-Object { ($_ -eq "*@gmail.com") -or ($_ -eq "@gmail.com") -or ($_ -eq "gmail.com") }
    if($Addresses) { 
        foreach ($Address in $Addresses) {
            $Results += [PSCustomObject][ordered] @{ Date=$Date; CustomerName=$CustomerName; Address=$Address; Issue="Allow List - Gmail Domain"; Action="Remove domain" }
            $CountIssues ++
        }
    }

    $Addresses = $AllowList | Where-Object { ($_ -eq "*@amazonses.com") -or ($_ -eq "@amazonses.com") -or ($_ -eq "amazonses.com") -or ($_ -like "@*amazonses.com") -or ($_ -like "us*amazonses.com") }
    if($Addresses) { 
        foreach ($Address in $Addresses) {
            $Results += [PSCustomObject][ordered] @{ Date=$Date; CustomerName=$CustomerName; Address=$Address; Issue="Allow List - Amazon SES Domain"; Action="Remove domain" }
            $CountIssues ++
        }
    }

    # Audit deny list for popular domain(s)/address(es)
    
    $Addresses = $AllowList | Where-Object { ($_ -eq "*@gmail.com") -or ($_ -eq "@gmail.com") -or ($_ -eq "gmail.com") }
    if($Addresses) { 
        foreach ($Address in $Addresses) {
            $Results += [PSCustomObject][ordered] @{ Date=$Date; CustomerName=$CustomerName; Address=$Address; Issue="Deny List - Gmail Domain"; Action="Remove domain" }
            $CountIssues ++
        }
    }

    $Addresses = $DenyList | Where-Object { ($_ -eq "*@amazonses.com") -or ($_ -eq "@amazonses.com") -or ($_ -eq "amazonses.com") -or ($_ -like "@*amazonses.com") -or ($_ -like "us*amazonses.com") }
    if($Addresses) { 
        foreach ($Address in $Addresses) {
            $Results += [PSCustomObject][ordered] @{ Date=$Date; CustomerName=$CustomerName; Address=$Address; Issue="Deny List - Amazon SES Domain"; Action="Remove domain" }
            $CountIssues ++
        }
    }

}

# End processing

$EndTime = Get-Date
$TotalTime = ($EndTime-$StartTime).TotalSeconds
$Minutes = "{0:N0}" -f ($TotalTime/60)
$Seconds = "{0:N0}" -f ($TotalTime%60)

Write-Host "`r`nAudit conducted on Proofpoint allow/deny lists in $Minutes minutes and $Seconds seconds.`r`n"

Write-Host "$CountCustomers customer(s) audited."
Write-Host "$CountIssues issue(s) identified."

# Log results

if ($Logging -eq $true) {

    # Export log file

    Write-Host "CSV File created at $LogFile.`r`n"
    $Results | Sort CustomerName,Issue,Address | Export-CSV -Path $LogFile -NoTypeInformation 
    
    # Email the CSV and stats to admin(s) 

    $Body = ""
    
    if ($Results) { $Body+= "CSV Attached for $Date<br>" } else { $Body+="No CSV Attached for $Date - No Results<br>" }

    $Body+="    
    Audit conducted on Proofpoint allow/deny lists in $Minutes minutes and $Seconds seconds.<br>
    <br>
    $CountCustomers customer(s) audited.<br>
    $CountIssues issue(s) identified.
    "

    # Format the email parameters

    $SmtpServer  = $CustomerSettings.SmtpServer
    $Port        = $CustomerSettings.SmtpPort
    $From        = $CustomerSettings.SmtpFrom
    $To          = $ToEmailAddr
    $Subject     = "Proofpoint Customer Audit - Allow/Deny Lists"
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