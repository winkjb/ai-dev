<#
.SYNOPSIS
    This script audits customer administrators in PowerDMARC

.DESCRIPTION
    This 

.EXAMPLE
    .\Export-CustomerAdmins.ps1
#>

[CmdletBinding()]
param(

    [string[]]$ExcludedAdmins,
    [switch]$EnabledOnly = $false,
    [switch]$LogExclusions = $false

) 

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

# System settings and variables

$OutputDir = Join-Path $PSScriptRoot ".\output"
$OutputSummaryCustomers = Join-Path $OutputDir "proofpointadmins-customer.csv"
$OutputSummaryServit = Join-Path $OutputDir "proofpointadmins-customer.csv"

# Import functions

. (Join-Path $PSScriptRoot "..\..\scripts\Functions-VA-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\scripts\Functions-Proofpoint-Common.ps1")

# Import settings and validate output directory

$Settings = Import-Settings -SettingsPath "..\..\data\reference\ProofpointSettings.txt"
Test-Directory $OutputDir

# ---------------------------------------------------------------------------
# Step 1: Get all tenants  
# ---------------------------------------------------------------------------

# Script settings and variables

$Date = Get-Date -Format yyyy-MM-dd
$i = 0
$CountAdminsCustomers = 0
$CountAdminsServit = 0
$CountExclusions = 0
$CountResults = 0

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

    Write-Host "[$i/$($CountCustomers)] Auditing customer: $($Customer.name)" -ForegroundColor Yellow

    # Get customer admins

    $Uri = "https://us2.proofpointessentials.com/api/v1/orgs/"+$Customer.primary_domain+"/users/"
    $ApiResponse = Invoke-RestMethod -Uri $Uri -Headers $ApiContext.Headers

    # Filter admins

    if ($EnabledOnly -eq $false) { 
        $Admins = $ApiResponse.users.Where({ $_.type -like "*admin" })
    } else { 
        $Admins = $ApiResponse.users.Where({ $_.type -like "*admin" -and $_.is_active -eq $true }) 
    }

    # Log finding

    foreach ($Admin in $Admins) {
        
        $CountAdmins++

        # Identify exclusions

        $InExclusion = $ExcludedAdmins -contains $Admin.primary_email

        if ($InExclusion) { $CountExclusions++ }

        # Log finding

        if (-not $InExclusion -or $LogExclusions) {

            if ($Customer.name -eq "ServIT MSP") {
                $CountAdminsServit++
            } else {
                $CountAdminsCustomers++
            }

            # Normalize finding

            $Finding = [ordered] @{ 
                
                Date          = $Date
                CustomerName  = $Customer.name
                FirstName     = $Admin.firstname
                LastName      = $Admin.surname
                Username      = $Admin.primary_email
                Role          = $Admin.type
                ReadOnlyUser  = $Admin.read_only_user
                CreationDate  = $Admin.creation_date
                LastLogin     = $Admin.last_login
                DaysAgo       = Get-DaysSince -Value $Admin.last_login
                Enabled       = $Admin.is_active

            }

            if ($LogExclusions) { $Finding.InExclusionGroup = if ($InExclusion) {"Y"} else {$null} }

            $CountResults++

            [PSCustomObject]$Finding

        }
          
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

Write-Host "`r`nAudit conducted on Proofpoint admins in $Minutes minutes and $Seconds seconds.`r`n" -ForegroundColor Green

Write-Host "Tenants: $CountCustomers total." -ForegroundColor Blue
Write-Host "Admins: $CountAdmins found ($CountAdminsCustomers customers / $CountAdminsServit ServIT), $CountExclusions excluded, $CountResults logged." -ForegroundColor Blue

$Results | Sort-Object CustomerName,Role,FirstName | Export-CSV -Path $OutputSummaryCustomers -NoTypeInformation
