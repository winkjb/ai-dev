<#
.SYNOPSIS
    This script audits billable domains in PowerDMARC for billing

.DESCRIPTION
    This 

.EXAMPLE
    .\Export-BillableDomains.ps1
#>

[CmdletBinding()]
param() 

    $EnabledOnly = $false # Set to $true to only capture enabled admins
    $LogExclusions = $false # Set to $false to only capture issues

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

# System settings and variables

$OutputDir = Join-Path $PSScriptRoot ".\output"
$OutputSummary = Join-Path $OutputDir "admins-customer.csv"

# Import functions

. (Join-Path $PSScriptRoot "..\..\scripts\Functions-VA-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\scripts\Functions-Proofpoint-Common.ps1")

# Import settings and validate output directory

$Settings = Import-Settings -SettingsPath "..\..\data\reference\ProofpointSettings.txt"
Test-Directory $OutputDir

# ---------------------------------------------------------------------------
# Step 1: Get all customers  
# ---------------------------------------------------------------------------

# Script settings and variables

$Date = Get-Date -Format yyyy-MM-dd
$CountCustomers = 0
$CountAdmins = 0
$CountExclusions = 0
$CountResults = 0
$i = 0
$Results = @()

# Import settings and set API context

Write-Host "Connecting to Proofpoint..." -ForegroundColor Cyan
$ApiContext = Set-ProofpointApiContext -Settings $Settings

# Start processing

$StartTime = Get-Date

# Get customers and page results

$Uri = "https://us2.proofpointessentials.com/api/v1/orgs/servit.net/orgs"
$ApiResponse = Invoke-RestMethod -Uri $Uri -Headers $ApiContext.Headers
$Customers = $ApiResponse.orgs 

if (-not $Customers -or $Customers.Count -eq 0) {
    Write-Error "No customers returned. Check credentials and API access scope."
    return
}

$CountCustomers = @($Customers).count

Write-Host "Found $CountCustomers customer(s)." -ForegroundColor Green

# ---------------------------------------------------------------------------
# Step 2: Audit customers  
# ---------------------------------------------------------------------------

# Iterate through customers

$Results = foreach ($Customer in $Customers) {

    $i++

    # Write-Progress -activity "Processing..." -status "$i out of $CountCustomers customers completed" -PercentComplete ([int](($i/$CountCustomers)*100))
    
    if ($Customer.name -like "ServIT*") { 
        
        Write-Host "[$i/$($CountCustomers)] Skipping customer: $($Customer.name) (excluded)" -ForegroundColor DarkGray        
        continue 
    
    }
    
    Write-Host "[$i/$($CountCustomers)] Auditing customer: $($Customer.name)" -ForegroundColor Yellow
    
    # Get customer admins

    $Uri = "https://us2.proofpointessentials.com/api/v1/orgs/"+$Customer.primary_domain+"/users/"
    $ApiResponse = Invoke-RestMethod -Uri $Uri -Headers $ApiContext.Headers

    # Filter admins

    if ($EnabledOnly -eq $false) { 
        $Admins = $ApiResponse.users | Where-Object { $_.type -like "*admin" }
    } else { 
        $Admins = $ApiResponse.users | Where-Object { $_.type -like "*admin" -and $_.is_active -eq $true } }
    
    # Log finding

    foreach ($Admin in $Admins) {
        
        $CountAdmins ++

        # Compare $Admins to excluded admins

        if ($ExcludedAdmins -contains $Admin.primary_email) {

            $CountExclusions ++
            if ($LogExclusions -eq $true) { 
            
            [PSCustomObject][ordered] @{ Date=$Date; CustomerName=$Customer.name; FirstName=$Admin.firstname; LastName=$Admin.surname; Username=$Admin.primary_email; Role=$Admin.type; ReadOnlyUser=$Admin.read_only_user; CreationDate=$Admin.creation_date; LastLogin=$Admin.last_login; Enabled=$Admin.is_active; InExclusionGroup="Y" }
            $CountResults++
            
            }

        } else {
    
            [PSCustomObject][ordered] @{ Date=$Date; CustomerName=$Customer.name; FirstName=$Admin.firstname; LastName=$Admin.surname; Username=$Admin.primary_email; Role=$Admin.type; ReadOnlyUser=$Admin.read_only_user; CreationDate=$Admin.creation_date; LastLogin=$Admin.last_login; Enabled=$Admin.is_active; InExclusionGroup="N" }
            $CountResults ++

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
    $Subject     = "Proofpoint Admin Audit - Customers"
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