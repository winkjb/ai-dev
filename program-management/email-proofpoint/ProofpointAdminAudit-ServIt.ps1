################################################################################################################### 
##
## This script audits customer admin users in Proofpoint Essentials Email Security
## Version 1.2
##
## Search and analysis variables
$SettingsPath = "C:\PS\servit-msp\Settings\CustomerSettings.txt"
$ExcludedAdmins = @("automation.admin@servit.net")
$EnabledOnly = $false # Set to $true to only capture enabled admins
$LogExclusions = $false # Set to $false to only capture issues
##
## Output options 
$Logging = $true # Set to $false to Disable Logging
$LogFile = "C:\PS\servit-msp\Logs\ProofpointAdminAudit-ServIt.csv" # ie. c:\mylog.csv
$ToEmailAddr = @("bwinklesky@servit.net") # Multiple addr allowed but MUST be independent strings separated by comma
##
################################################################################################################### 

# System settings and variables

$Date = Get-Date -Format yyyy-MM-dd
$CountCustomers = 0
$CountAdmins = 0
$CountExclusions = 0
$CountResults = 0
$i = 0
$Customers = @()
$Admins = @()
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

    Write-Progress -activity "Processing..." -status "$i out of $CountCustomers customers completed" -PercentComplete ([int](($i/$CountCustomers)*100))
    
    if ($Customer.name -notlike "ServIT*") { continue } 
    
    # Get customer admins

    $Uri = "https://us2.proofpointessentials.com/api/v1/orgs/"+$Customer.primary_domain+"/users/"
    $ApiResponse = Invoke-RestMethod -Uri $Uri -Headers $Headers

    # Filter admins

    if ($EnabledOnly -eq $false) { 
        $Admins = $ApiResponse.users | Where-Object { $_.type -like "*admin" }
    } else { 
        $Admins = $ApiResponse.users | Where-Object { $_.type -like "*admin" -and $_.is_active -eq $true } }
    
    # Audit admins

    foreach ($Admin in $Admins) {
        
        $CountAdmins ++

        # Compare $Admins to excluded admins

        if ($ExcludedAdmins -contains $Admin.primary_email) {

            $CountExclusions ++
            if ($LogExclusions -eq $true) { 
            
            $Results += [PSCustomObject][ordered] @{ Date=$Date; CustomerName=$Customer.name; FirstName=$Admin.firstname; LastName=$Admin.surname; Username=$Admin.primary_email; Role=$Admin.type; ReadOnlyUser=$Admin.read_only_user; CreationDate=$Admin.creation_date; LastLogin=$Admin.last_login; Enabled=$Admin.is_active; InExclusionGroup="Y" }
            $CountResults++
            
            }

        } else {
    
            $Results += [PSCustomObject][ordered] @{ Date=$Date; CustomerName=$Customer.name; FirstName=$Admin.firstname; LastName=$Admin.surname; Username=$Admin.primary_email; Role=$Admin.type; ReadOnlyUser=$Admin.read_only_user; CreationDate=$Admin.creation_date; LastLogin=$Admin.last_login; Enabled=$Admin.is_active; InExclusionGroup="N" }
            $CountResults++

        }
          
    }

}

# End processing

$EndTime = Get-Date
$TotalTime = ($EndTime-$StartTime).TotalSeconds
$Minutes = "{0:N0}" -f ($TotalTime/60)
$Seconds = "{0:N0}" -f ($TotalTime%60)

Write-Host "`r`nAudit conducted on Proofpoint admins in $Minutes minutes and $Seconds seconds.`r`n"

Write-Host "$i customer(s) audited."
Write-Host "$CountAdmins admin(s) audited."
Write-Host "$CountExclusions admin(s) in exclusion groups."
Write-Host "$CountResults admin(s) identified."

# Log results

if ($Logging -eq $true) {

    # Export log file

    Write-Host "CSV File created at $LogFile.`r`n"
    $Results | Sort CustomerName,Role,FirstName | Export-CSV -Path $LogFile -NoTypeInformation 
    
    # Email the CSV and stats to admin(s) 

    $Body = ""
    
    if ($Results) { $Body+= "CSV Attached for $Date<br>" } else { $Body+="No CSV Attached for $Date - No Results<br>" }

    $Body+="    
    Audit conducted on Proofpoint admins in $Minutes minutes and $Seconds seconds.<br>
    <br>
    $i customer(s) audited.<br>
    $CountAdmins admin(s) audited.<br>
    $CountExclusions admin(s) in exclusion groups.<br>
    $CountResults admin(s) identified.
    "

    # Format the email parameters

    $SmtpServer  = $CustomerSettings.SmtpServer
    $Port        = $CustomerSettings.SmtpPort
    $From        = $CustomerSettings.SmtpFrom
    $To          = $ToEmailAddr
    $Subject     = "Proofpoint Admin Audit - ServIT"
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