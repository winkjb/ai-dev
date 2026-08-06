################################################################################################################### 
##
## This script audits billable domains in PowerDMARC
## Version 1.1
##
## Search and analysis variables
$SettingsPath = "C:\PS\servit-msp\Settings\CustomerSettings.txt"
##
## Output options 
$Logging = $true # Set to $false to Disable Logging
$LogFile = "C:\PS\servit-msp\Logs\PowerDmarcDomainAudit-BillableDomains.csv" # ie. c:\mylog.csv
$ToEmailAddr = @("bwinklesky@servit.net","tmarsili@servit.net","nleverett@servit.net","chart@servit.net") # Multiple addr allowed but MUST be independent strings separated by comma
##
################################################################################################################### 

# System settings and variables

$Date = Get-Date -Format yyyy-MM-dd
$DateFrom = (Get-Date).AddDays(-30).ToString("yyyy-MM-dd")
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

$Uri = "https://servit.powerdmarc.com/api/v1/mssp/accounts?per_page=50&dateFrom=$DateFrom&dateTo=$Date"
$Headers = @{
        "Authorization" = "Bearer "+$CustomerSettings.PowerDmarcToken+""
        "Accept" = "application/json" }
$ApiResponse = Invoke-RestMethod -Uri $Uri -Headers $Headers

# Page results

$Customers = $ApiResponse.data 
$CountCustomers = $Customers.count

# Audit customers

foreach ($Customer in $Customers) {

    $i++

    Write-Progress -activity "Processing..." -status "$i out of $CountCustomers customers completed" -PercentComplete ([int](($i/$CountCustomers)*100))
    
    if ($Customer.name -like "ServIT*") { continue } 
    
    # Audit customers

    $CustomerName = $Customer.name
    $Plan = $Customer.plan.name
    $BillableDomains = $Customer.active_domains_count

    $Results += [PSCustomObject][ordered] @{ 
    
        Date              = $Date
        CustomerName      = $CustomerName
        Plan              = $Plan
        BillableDomains   = $BillableDomains 
    
    }
    
    $CountResults++

}

# End processing

$EndTime = Get-Date
$TotalTime = ($EndTime-$StartTime).TotalSeconds
$Minutes = "{0:N0}" -f ($TotalTime/60)
$Seconds = "{0:N0}" -f ($TotalTime%60)

Write-Host "`r`nAudit conducted on PowerDMARC customers in $Minutes minutes and $Seconds seconds.`r`n"

Write-Host "$CountResults customer(s) identified."

# Log results

if ($Logging -eq $true) {

    if ($LogFile) { 

        # Export log file

        Ensure-Directory ($LogFile)
        $Results | Sort CustomerName | Export-CSV -Path $LogFile -NoTypeInformation 
        Write-Host "CSV File created at $LogFile.`r`n"

    }

    if ($ToEmailAddr) {
    
        # Email the CSV and stats to admin(s) 

        $Body = ""
    
        if ($Results) { $Body+= "CSV Attached for $Date<br>" } else { $Body+="No CSV Attached for $Date - No Results<br>" }

        $Body+="
        Audit conducted on PowerDMARC customers in $Minutes minutes and $Seconds seconds.<br>
        <br>
        $CountResults customer(s) identified.<br>
        "
        # Format the email parameters

        $SmtpServer  = $CustomerSettings.SmtpServer
        $Port        = $CustomerSettings.SmtpPort
        $From        = $CustomerSettings.SmtpFrom
        $To          = $ToEmailAddr
        $Subject     = "PowerDMARC Domain Audit - Billable Domains"
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