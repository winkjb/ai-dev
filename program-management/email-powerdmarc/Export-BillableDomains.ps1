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
. (Join-Path $PSScriptRoot "..\..\scripts\Functions-PowerDmarc-Common.ps1")

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
$CountResultsSummary = 0
$CountResultsDetail = 0
$ResultsDetail = @()

# Import settings and set API context

Write-Host "Connecting to PowerDMARC..." -ForegroundColor Cyan
$ApiContext = Set-PowerDmarcApiContext -Settings $Settings

# Start processing

$StartTime = Get-Date

# Get customers and page results

$ApiResponse = Get-AllPowerDmarcResults -Uri $ApiContext.Uri -Headers $ApiContext.Headers
$Customers = $ApiResponse

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

$ResultsSummary = foreach ($Customer in $Customers) {

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

    # Log finding

    [PSCustomObject][ordered] @{

        Date              = $Date
        CustomerName      = $CustomerName
        Plan              = $Plan
        BillableDomains   = $BillableDomains

    }

    $CountResultsSummary++

    # Log finding

    foreach ($Domain in $Customer.domains) {

        $ResultsDetail += [PSCustomObject][ordered] @{

            Date                   = $Date
            CustomerName           = $CustomerName
            Domain                 = $Domain.name
            DmarcRecordCorrect     = $Domain.is_dmarc_record_correct
            SetupCompleted         = $Domain.is_setup_completed

        }

        $CountResultsDetail++

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
Write-Host "$CountResultsSummary customer(s) logged." -ForegroundColor Blue
Write-Host "$CountResultsDetail domain(s) logged." -ForegroundColor Blue

$ResultsSummary | Sort-Object CustomerName | Export-Csv -Path $OutputSummary -NoTypeInformation
$ResultsDetail | Sort-Object CustomerName, Domain | Export-Csv -Path $OutputDetail -NoTypeInformation
