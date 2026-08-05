################################################################################################################### 
##
## This script pulls user and sign in info from Azure Active Directory
## Version 1.6 (Custom)
##
################################################################################################################### 

& (Join-Path $PSScriptRoot "Export-DiverzifyUserReport.ps1") -ExcludedUsers "scanner@diverzify.com" -Logging $true