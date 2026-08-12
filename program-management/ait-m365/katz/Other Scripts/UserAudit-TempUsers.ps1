################################################################################################################### 
##
## Script wrapper
## Version 1.0
##
## Search and analysis variables
$CustomerName = "Ameriserve"
$ExcludedUsers = @() # Multiple groups allowed but MUST be independent strings separated by comma
$EnabledUsersOnly = $false # Set to $true to only capture enabled users
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

$ScriptPath = "C:\PS\Scripts\Ad-Azure\UserAudit-TempUsers-Default.ps1"

# Build parameters

$Params = @{
    Directory      = $CustomerInfo.Directory
    CustomerFolder = $CustomerInfo.CustomerFolder
    ExcludedUsers  = $ExcludedUsers
    ToEmailAddr    = $ToEmailAddr
}

if ($EnabledUsersOnly) { $Params.EnabledUsersOnly = $true }
if ($LogExclusions) { $Params.LogExclusions = $true }

if ($Logging) { $Params.Logging = $true }

# Run script

& $ScriptPath @Params