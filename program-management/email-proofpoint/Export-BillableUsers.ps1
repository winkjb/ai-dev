<#
.SYNOPSIS
    This script audits billable users in Proofpoint for billing

.DESCRIPTION
    This 

.EXAMPLE
    .\Export-BillableUsers.ps1
#>

[CmdletBinding()]
param()

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

# System settings and variables

$OutputDir = Join-Path $PSScriptRoot ".\output"
$OutputSummary = Join-Path $OutputDir "billable-users-summary.csv"

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
$i = 0
$CountCustomersSkipped = 0
$CountResults = 0
$Customers = @()
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

    # Normalize  customer information

    $CustomerName = $Customer.name
    $Package = $Customer.licensing_package
    $BillableUsers = $Customer.active_users

    if ($CustomerName -like "ServIT*") { 
        
        $CountCustomersSkipped++
        Write-Host "[$i/$($CountCustomers)] Skipping customer: $CustomerName (excluded)" -ForegroundColor DarkGray       
        continue 
    
    }
    
    $CountCustomersAudited++
    Write-Host "[$i/$($CountCustomers)] Auditing customer: $($CustomerName)" -ForegroundColor Yellow

    [PSCustomObject][ordered] @{ 
        
        Date           = $Date
        CustomerName   = $CustomerName
        Package        = $Package
        BillableUsers  = $BillableUsers 
    
    }

    $CountResults++

}

# End processing

$EndTime = Get-Date
$TotalTime = ($EndTime-$StartTime).TotalSeconds
$Minutes = "{0:N0}" -f ($TotalTime/60)
$Seconds = "{0:N0}" -f ($TotalTime%60)

Write-Host "`r`nAudit conducted on Proofpoint customers in $Minutes minutes and $Seconds seconds.`r`n" -ForegroundColor Green

Write-Host "Customers: $CountCustomers total, $CountResults audited, $CountCustomersSkipped skipped." -ForegroundColor Blue

$Results | Sort-Object CustomerName | Export-CSV -Path $OutputSummary -NoTypeInformation