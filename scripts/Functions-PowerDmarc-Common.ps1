###################################################################################################################
##
## This script contains shared PowerDMARC functions to dot source
## Version 1.0
##
###################################################################################################################

function Set-PowerDmarcApiContext {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Settings
    )

    try {
        $Domain = $Settings.Domain
        $ApiToken = $Settings.ApiToken
        
        $Headers = @{
            "Authorization" = "Bearer "+$ApiToken+""
            "Accept" = "application/json" 
        }

        $Uri = "https://$Domain.powerdmarc.com/api/v1/mssp/accounts?per_page=50&dateFrom=$DateFrom&dateTo=$Date"

        return [PSCustomObject]@{
            Headers  = $Headers
            Uri  = $Uri
        }
    }
    catch {
        throw "Set-PowerDmarcApiContext failed: $($_.Exception.Message)"
    }

}

function Get-AllPowerDmarcResults {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter(Mandatory)]
        [hashtable]$Headers
    )

    try {

        $Results = @()

        $ApiResponse = Invoke-RestMethod -Uri $Uri -Headers $Headers
        $Results += $ApiResponse.data

        $Page = $ApiResponse.meta.current_page
        $LastPage = $ApiResponse.meta.last_page

        while ($Page -lt $LastPage) {

            $Page++
            $PageResponse = Invoke-RestMethod -Uri "$($Uri)&page=$Page" -Headers $Headers
            $Results += $PageResponse.data

        }

        return $Results

    }
    catch {
        throw "Get-AllPowerDmarcResults failed: $($_.Exception.Message)"
    }

}