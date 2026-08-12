################################################################################################################### 
##
## Script wrapper
## Version 1.0
##
## Search and analysis variables
$CustomerName = "Ameriserve"
$ExcludedTeams = @() # Multiple teams allowed but MUST be independent strings separated by comma
$ReportingDays = 180 # Days of activity this script will report on (valid entries are 7,30,90 and 180) 
$LogExclusions = $false # Set to $false to only capture issues
##
## Output options 
$Logging = $true # Set to $false to Disable Logging
$ToEmailAddr = @() # Multiple addr allowed but MUST be independent strings separated by comma
##
###################################################################################################################

# Import functions

. "C:\PS\Scripts\VA-Functions.ps1"

# Normalize customer information

$CustomerInfo = Map-Customer -CustomerName $CustomerName

# Shared/default script to call

$ScriptPath = "C:\PS\Scripts\Ad-Azure\SiteAuditTeams-Activity-Default.ps1"

# Build parameters

$Params = @{
    Directory      = $CustomerInfo.Directory
    CustomerFolder = $CustomerInfo.CustomerFolder
    ExcludedTeams  = $ExcludedTeams
    ReportingDays  = $ReportingDays
    ToEmailAddr    = $ToEmailAddr
}

if ($LogExclusions) { $Params.LogExclusions = $true }

if ($Logging) { $Params.Logging = $true }

# Run script

& $ScriptPath @Params