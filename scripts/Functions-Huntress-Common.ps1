###################################################################################################################
##
## Shared Huntress REST API functions, dot source this file to use them. Security-team-specific (not workspace-
## wide like scripts/Functions-Autotask-Common.ps1) - only the security team's reports talk to Huntress today.
## Generic mechanics only - entity-specific filtering/shaping belongs in the caller.
##
###################################################################################################################

$CommonScript = Join-Path $PSScriptRoot "Functions-VA-Common.ps1"
if (-not (Get-Command Import-Settings -ErrorAction SilentlyContinue)) {
    . $CommonScript
}

function Set-HuntressApiContext {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [array]$Settings
    )

    try {
        $ApiKey = $Settings.ApiKey
        $SecretKey = $Settings.SecretKey

        $b64Creds = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($ApiKey):$($SecretKey)"))
        $Headers = @{ Authorization = "Basic $b64Creds" }

        $BaseUrl = "https://api.huntress.io/v1/"

        return [PSCustomObject]@{
            Headers  = $Headers
            BaseUrl  = $BaseUrl
        }
    }
    catch {
        throw "Set-HuntressApiContext failed: $($_.Exception.Message)"
    }

}

function Get-AllHuntressResults {

    # GETs the given endpoint and follows pagination.next_page_url until exhausted,
    # returning every item across all pages (Huntress's own cursor-token pagination -
    # confirmed live: response includes a ready-to-use next_page_url, no need to build
    # page tokens by hand).

    [CmdletBinding()]

    param(
        [Parameter(Mandatory)] $Connection,
        [Parameter(Mandatory)] [string]$Endpoint,

        # Query string params, e.g. @{ status = "sent"; organization_id = 646212 }
        [hashtable]$QueryParams = @{},

        # Key in the response body holding the array of items - defaults to the endpoint
        # name itself (e.g. "escalations" for the "escalations" endpoint), since that's
        # Huntress's own convention.
        [string]$ResourceKey,

        [int]$Limit = 100
    )

    if (-not $ResourceKey) { $ResourceKey = $Endpoint }

    $Params = @{} + $QueryParams
    $Params["limit"] = $Limit
    $QueryString = ($Params.GetEnumerator() | ForEach-Object {
        "$($_.Key)=$([Uri]::EscapeDataString([string]$_.Value))"
    }) -join "&"

    $Items = [System.Collections.Generic.List[object]]::new()
    $Uri = "$($Connection.BaseUrl)$Endpoint" + $(if ($QueryString) { "?$QueryString" } else { "" })

    while ($Uri) {
        $Response = Invoke-RestMethod -Uri $Uri -Headers $Connection.Headers -Method Get
        foreach ($item in $Response.$ResourceKey) { $Items.Add($item) }
        $Uri = $Response.pagination.next_page_url
    }

    return $Items
}
