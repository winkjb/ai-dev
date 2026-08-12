################################################################################################################### 
##
## Script wrapper
## Version 1.0
##
## Search and analysis variables
$CustomerName = "Ameriserve"
$ExcludedTeams = @() # Multiple teams allowed but MUST be independent strings separated by comma
$LessThanDays = 180 # After this many days since last activity, team will be disabled
$LogExclusions = $false # Set to $false to only capture issues
$Testing = $true # Set to true to report only and take no action
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

$ScriptPath = "C:\PS\Scripts\Ad-Azure\SiteAuditTeams-Disable-Default.ps1"

# Build parameters

$Params = @{
    Directory      = $CustomerInfo.Directory
    CustomerFolder = $CustomerInfo.CustomerFolder
    ExcludedTeams  = $ExcludedTeams
    LessThanDays   = $LessThanDays
    ToEmailAddr    = $ToEmailAddr
}

if ($LogExclusions) { $Params.LogExclusions = $true }
if ($Testing) { $Params.Testing = $true }

if ($Logging) { $Params.Logging = $true }

# Run script

& $ScriptPath @Params