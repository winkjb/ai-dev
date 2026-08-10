###################################################################################################################
##
## This script contains shared RocketCyber functions to dot source
## Version 1.0
##
###################################################################################################################

function Set-RocketCyberApiContext {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Settings
    )

    try {
        $Token = $Settings.ApiToken

        $Headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }

        return [PSCustomObject]@{
            Headers = $Headers
        }
    }
    catch {
        throw "Set-RocketCyberApiContext failed: $($_.Exception.Message)"
    }

}

function Get-AllRocketCyberResults {

    # RocketCyber's v3 API paginates by page number, not a cursor - response envelope
    # is { totalCount, currentPage, totalPages, dataCount, data }. Confirmed live
    # 2026-08-10 against /incidents and /agents.

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseUri,
        [Parameter(Mandatory)][hashtable]$Headers,
        [int]$PageSize = 1000
    )

    $AllResults = @()
    $Page = 1
    $TotalPages = 1

    do {
        $Separator = if ($BaseUri.Contains('?')) { '&' } else { '?' }
        $Uri = "$BaseUri${Separator}page=$Page&pageSize=$PageSize"

        $Response = Invoke-RestMethod -Method Get -Uri $Uri -Headers $Headers

        if ($Response.data) {
            $AllResults += @($Response.data)
        }

        $TotalPages = $Response.totalPages
        $Page++

    } while ($Page -le $TotalPages)

    return $AllResults

}