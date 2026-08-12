################################################################################################################### 
##
## Script wrapper
## Version 1.0
##
## Search and analysis variables
$CustomerName = "Ameriserve"
$StorageMoreThan = 75 # Users with a mailbox usage percentage higher than this will be reported
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

$ScriptPath = "C:\PS\Scripts\Ad-Azure\MailboxAudit-Size-Default.ps1"

# Build parameters

$Params = @{
    Directory       = $CustomerInfo.Directory
    CustomerFolder  = $CustomerInfo.CustomerFolder
    StorageMoreThan = $StorageMoreThan
    ToEmailAddr     = $ToEmailAddr
}

if ($Logging) { $Params.Logging = $true }

# Run script

& $ScriptPath @Params