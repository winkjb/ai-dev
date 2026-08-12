################################################################################################################### 
##
## Script wrapper
## Version 1.0
##
## Search and analysis variables
$CustomerName = "Ameriserve"
$AdminGroups = @("Billing Administrator","User Administrator","Exchange Administrator","Global Administrator","Global Reader") # Enter all groups to audit
$LessThanDays = 90 # After this many days since last logon, admin user will be consider aged
$LogDisabledUsers = $true # Set to $false to only capture enabled users
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

$ScriptPath = "C:\PS\Scripts\Ad-Azure\GroupMemberAudit-Admins-Default.ps1"

# Build parameters

$Params = @{
    Directory      = $CustomerInfo.Directory
    CustomerFolder = $CustomerInfo.CustomerFolder
    AdminGroups    = $AdminGroups
    LessThanDays   = $LessThanDays
    ToEmailAddr    = $ToEmailAddr
}

if ($LogDisabledUsers) { $Params.LogDisabledUsers = $true }

if ($Logging) { $Params.Logging = $true }

# Run script

& $ScriptPath @Params