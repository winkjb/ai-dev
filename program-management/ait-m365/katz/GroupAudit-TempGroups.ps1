################################################################################################################### 
##
## Script wrapper
## Version 1.0
##
################################################################################################################### 

# Import functions

. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-VA-Common.ps1")

# Normalize customer information

# $CustomerInfo = Map-Customer -CustomerName $CustomerName
$CustomerInfo = @{
    Directory = "katz"
    CustomerFolder = "Katz"
}

# Shared/default script to call

$ScriptPath = "..\scripts\shared\GroupAudit-TempGroups-Default.ps1"

# Build parameters

$Params = @{
    Directory      = $CustomerInfo.Directory
    CustomerFolder = $CustomerInfo.CustomerFolder
    ExcludedGroups = $ExcludedGroups
    ToEmailAddr    = $ToEmailAddr
}

if ($LogExclusions) { $Params.LogExclusions = $true }

if ($Logging) { $Params.Logging = $true }

# Run script

& $ScriptPath @Params