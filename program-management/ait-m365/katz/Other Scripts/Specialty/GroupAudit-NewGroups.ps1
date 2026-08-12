################################################################################################################### 
##
## Script wrapper
## Version 1.0
##
## Search and analysis variables
$CustomerName = "Ameriserve"
$LessThanDaysAgo = 30 # Users with a creation date newer than this will be assessed
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

$ScriptPath = "C:\PS\Scripts\Ad-Azure\GroupAudit-NewGroups-Default.ps1"

# Build parameters

$Params = @{
    Directory       = $CustomerInfo.Directory
    CustomerFolder  = $CustomerInfo.CustomerFolder
    LessThanDaysAgo = $LessThanDaysAgo
    ToEmailAddr     = $ToEmailAddr
}

if ($LogExclusions) { $Params.LogExclusions = $true }

if ($Logging) { $Params.Logging = $true }

# Run script

& $ScriptPath @Params