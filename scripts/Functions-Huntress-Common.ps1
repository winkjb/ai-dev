###################################################################################################################
##
## This script contains shared Huntress functions to dot source
## Version 1.0
##
###################################################################################################################

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

        $BaseUri = "https://api.huntress.io/v1/"

        return [PSCustomObject]@{
            Headers  = $Headers
            BaseUri  = $BaseUri
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
    $Uri = "$($Connection.BaseUri)$Endpoint" + $(if ($QueryString) { "?$QueryString" } else { "" })

    while ($Uri) {
        $Response = Invoke-RestMethod -Uri $Uri -Headers $Connection.Headers -Method Get
        foreach ($item in $Response.$ResourceKey) { $Items.Add($item) }
        $Uri = $Response.pagination.next_page_url
    }

    return $Items
}

function Get-HuntressOrganizationLookup {

    # Builds an organization_id -> name lookup via Add-ToIndex (Functions-VA-Common.ps1).
    # Needed for endpoints like incident_reports that only return organization_id, unlike
    # escalations which embeds the organization name directly on each item.

    [CmdletBinding()]

    param(
        [Parameter(Mandatory)] $Connection
    )

    $Orgs = Get-AllHuntressResults -Connection $Connection -Endpoint "organizations"

    $Lookup = @{}
    foreach ($org in $Orgs) {
        Add-ToIndex -Index $Lookup -Key ([string]$org.id) -Value $org.name
    }

    return $Lookup
}
