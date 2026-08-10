###################################################################################################################
##
## This script contains shared SentinelOne functions to dot source
## Version 1.0
##
###################################################################################################################

function Set-S1ApiContext {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Settings
    )

    try {
        $Token = $Settings.ApiToken
        
        $Headers = @{
            "Authorization" = "ApiToken $Token"
            "Content-Type" = "application/json"
        }

        return [PSCustomObject]@{
            Headers = $Headers
        }
    }
    catch {
        throw "Set-S1ApiContext failed: $($_.Exception.Message)"
    }

}

function Get-AllS1Results {
    
    param(
        [Parameter(Mandatory)][string]$BaseUri,
        [Parameter(Mandatory)][hashtable]$Headers,
        [int]$Limit = 1000
    )

    $AllResults = @()
    $Cursor = $null

    do {
        if ($BaseUri.Contains('?')) {
            $Uri = '{0}&limit={1}' -f $BaseUri, $Limit
        } else {
            $Uri = '{0}?limit={1}' -f $BaseUri, $Limit
        }

        if ($Cursor) {
            $Uri += '&cursor={0}' -f [uri]::EscapeDataString($Cursor)
        }

        $Response = Invoke-RestMethod -Method Get -Uri $Uri -Headers $Headers

        if ($Response.data) {        
            $AllResults += @($Response.data)
        }

        $Cursor = $Response.pagination.nextCursor

    } while ($Cursor)

    return $AllResults

}   
