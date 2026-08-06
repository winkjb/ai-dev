###################################################################################################################
##
## This script contains shared Proofpoint functions to dot source
## Version 1.0
##
###################################################################################################################

function Set-ProofpointApiContext {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Settings
    )

    try {
        $Username = $Settings.Username
        $Password = $Settings.Password
        
        $Headers = @{
            'X-User' = $Username
            'X-Password' = $Password 
        }

        return [PSCustomObject]@{
            Headers  = $Headers
        }
    }
    catch {
        throw "Set-ProofpointApiContext failed: $($_.Exception.Message)"
    }

}

function Get-AllProofpointResults {

    

}