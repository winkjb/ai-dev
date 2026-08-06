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

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

# System settings and variables

$OutputDir = Join-Path $PSScriptRoot ".\output"
$OutputSummary = Join-Path $OutputDir "billable-domains-summary.csv"
$OutputDetail = Join-Path $OutputDir "billable-domains-detail.csv"

# Import functions

. (Join-Path $PSScriptRoot "..\..\scripts\Functions-VA-Common.ps1")

# Additional functions

function Set-PowerDmarcApiContext {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Settings
    )

    try {
        $Domain = $Settings.Domain
        $ApiToken = $Settings.ApiToken
        
        $Headers = @{
            "Authorization" = "Bearer "+$ApiToken+""
            "Accept" = "application/json" 
        }


        $Uri = "https://$Domain.powerdmarc.com/api/v1/mssp/accounts?per_page=50&dateFrom=$DateFrom&dateTo=$Date"

        return [PSCustomObject]@{
            Headers  = $Headers
            Uri  = $Uri
        }
    }
    catch {
        throw "Set-PowerDmarcApiContext failed: $($_.Exception.Message)"
    }

}

# Import settings and validate output directory

$Settings = Import-Settings -SettingsPath "..\..\data\reference\PowerDmarcSettings.txt"
Test-Directory $OutputDir

# ---------------------------------------------------------------------------
# Step 1: Get all customers  
# ---------------------------------------------------------------------------

# Script settings and variables

$DateFrom = (Get-Date).AddDays(-30).ToString("yyyy-MM-dd")
$Date = Get-Date -Format yyyy-MM-dd
$i = 0
$CountResults = 0
$CountDomains = 0
$DetailResults = @()

# Import settings and set API context

Write-Host "Connecting to PowerDMARC..." -ForegroundColor Cyan
$ApiContext = Set-PowerDmarcApiContext -Settings $Settings

# Start processing

$StartTime = Get-Date

# Get customers and page results

$ApiResponse = Invoke-RestMethod -Uri $ApiContext.Uri -Headers $ApiContext.Headers
$Customers = @($ApiResponse.data)

$Page = $ApiResponse.meta.current_page
$LastPage = $ApiResponse.meta.last_page

while ($Page -lt $LastPage) {

    $Page++
    $PageResponse = Invoke-RestMethod -Uri "$($ApiContext.Uri)&page=$Page" -Headers $ApiContext.Headers
    $Customers += $PageResponse.data

}

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

    # Normalize customer information

    $CustomerName = $Customer.name
    $Plan = $Customer.plan.name
    $BillableDomains = $Customer.active_domains_count
    
    # Write-Progress -activity "Processing..." -status "$i out of $CountCustomers customers completed" -PercentComplete ([int](($i/$CountCustomers)*100))
    
    if ($CustomerName -like "ServIT*") { 
        
        Write-Host "[$i/$($CountCustomers)] Skipping customer: $CustomerName (excluded)" -ForegroundColor DarkGray        
        continue 
    
    }

    Write-Host "[$i/$($CountCustomers)] Auditing customer: $CustomerName" -ForegroundColor Yellow

    [PSCustomObject][ordered] @{

        Date              = $Date
        CustomerName      = $CustomerName
        Plan              = $Plan
        BillableDomains   = $BillableDomains

    }

    $CountResults++

    # Normalize domain information

    foreach ($Domain in $Customer.domains) {

        $DetailResults += [PSCustomObject][ordered] @{

            Date                   = $Date
            CustomerName           = $CustomerName
            Domain                 = $Domain.name
            DmarcRecordCorrect     = $Domain.is_dmarc_record_correct
            SetupCompleted         = $Domain.is_setup_completed

        }

        $CountDomains++

    }

}

# ---------------------------------------------------------------------------
# Step 3: Complete and output
# ---------------------------------------------------------------------------

# End processing

$EndTime = Get-Date
$TotalTime = ($EndTime-$StartTime).TotalSeconds
$Minutes = "{0:N0}" -f ($TotalTime/60)
$Seconds = "{0:N0}" -f ($TotalTime%60)

Write-Host "`r`nAudit conducted on PowerDMARC customers in $Minutes minutes and $Seconds seconds.`r`n" -ForegroundColor Green
Write-Host "$CountResults customer(s) logged." -ForegroundColor Blue
Write-Host "$CountDomains domain(s) logged." -ForegroundColor Blue

$Results | Sort-Object CustomerName | Export-Csv -Path $OutputSummary -NoTypeInformation
$DetailResults | Sort-Object CustomerName, Domain | Export-Csv -Path $OutputDetail -NoTypeInformation
