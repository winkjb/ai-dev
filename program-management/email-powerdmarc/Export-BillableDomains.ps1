<#
.SYNOPSIS
    

.DESCRIPTION
    

.EXAMPLE
    .\Export-BillableDomains.ps1
#>

[CmdletBinding()]
param()

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

# System settings and variables

$OutputDir = Join-Path $PSScriptRoot ".\output"
$Date = Get-Date -Format yyyy-MM-dd
$DateFrom = (Get-Date).AddDays(-30).ToString("yyyy-MM-dd")

# Derived settings and variables

$OutputCsv = Join-Path $OutputDir "billable-domains.csv"

# Import functions

. (Join-Path $PSScriptRoot "..\..\scripts\Functions-VA-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\scripts\Functions-Formatting-Common.ps1")

# Additional functions

function Set-PowerDmarcApiContext {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [array]$Settings
    )

    try {
        $ApiToken = $Settings.ApiToken
        
        $Headers = @{
            "Authorization" = "Bearer "+$ApiToken+""
            "Accept" = "application/json" 
        }


        $Uri = "https://servit.powerdmarc.com/api/v1/mssp/accounts?per_page=50&dateFrom=$DateFrom&dateTo=$Date"

        return [PSCustomObject]@{
            Headers  = $Headers
            Uri  = $Uri
        }
    }
    catch {
        throw "Set-PowerDmarcApiContext failed: $($_.Exception.Message)"
    }

}

# Validate output directory

Test-Directory $OutputDir

# Import settings and set API context

Write-Host "Connecting to PowerDMARC..." -ForegroundColor Cyan
$Settings = Import-Settings -SettingsPath "..\..\data\reference\PowerDmarcSettings.txt"
$ApiContext = Set-PowerDmarcApiContext -Settings $Settings





# $ToEmailAddr = @("bwinklesky@servit.net","tmarsili@servit.net","nleverett@servit.net","chart@servit.net") # Multiple addr allowed but MUST be independent strings separated by comma




# System settings and variables

$CountCustomers = 0
$i = 0
$CountResults = 0
$Customers = @()
$Results = @()

# Start processing

$StartTime = Get-Date

# Get customers

$ApiResponse = Invoke-RestMethod -Uri $ApiContext.Uri -Headers $ApiContext.Headers

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

$Results = @($Results | Sort CustomerName)
Export-Utf8NoBomCsv -Path $OutputCsv -InputObject $Results 

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