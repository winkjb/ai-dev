###################################################################################################################
##
## Shared Autotask REST API functions, dot source this file to use them. Workspace-wide (not team-specific) -
## any team's scripts that need to talk to Autotask should use this rather than rolling their own HTTP/auth/
## pagination handling. Generic mechanics only - entity-specific filtering/shaping belongs in the caller.
##
###################################################################################################################

$CommonScript = Join-Path $PSScriptRoot "VA-Functions-Common.ps1"
if (-not (Get-Command Import-Settings -ErrorAction SilentlyContinue)) {
    . $CommonScript
}
Add-Type -AssemblyName System.Net.Http

function Connect-Autotask {

    # Decrypts AutotaskSettings.txt, resolves the account's API zone, and returns a
    # ready-to-use connection object (HttpClient + base zone URL) for Invoke-AutotaskQuery.

    [CmdletBinding()]

    param(
        [string]$SettingsPath,
        [string]$KeyPath
    )

    if (-not $SettingsPath) { $SettingsPath = Join-Path $PSScriptRoot "..\data\reference\AutotaskSettings.txt" }

    $ImportParams = @{ SettingsPath = $SettingsPath }
    if ($KeyPath) { $ImportParams["KeyPath"] = $KeyPath }
    $Settings = Import-Settings @ImportParams

    $Username = $Settings.Username
    $Secret = $Settings.Password
    $ApiIntegrationCode = $Settings.TrackingIdentifier

    if (-not $Username -or -not $Secret -or -not $ApiIntegrationCode) {
        throw "Decrypted Autotask settings are missing Username, Password, or TrackingIdentifier."
    }

    # Unauthenticated - just tells us which webservicesN.autotask.net zone this account lives on.
    $ZoneLookupUri = "https://webservices.autotask.net/atservicesrest/v1.0/zoneInformation?user=$([Uri]::EscapeDataString($Username))"
    $Zone = Invoke-RestMethod -Uri $ZoneLookupUri -Method Get
    if (-not $Zone.url) { throw "Zone lookup returned no URL for user $Username." }

    $Client = New-Object System.Net.Http.HttpClient
    $Client.DefaultRequestHeaders.Add("ApiIntegrationCode", $ApiIntegrationCode)
    $Client.DefaultRequestHeaders.Add("UserName", $Username)
    $Client.DefaultRequestHeaders.Add("Secret", $Secret)

    [PSCustomObject]@{
        Client  = $Client
        ZoneUrl = $Zone.url
    }
}

function Invoke-AutotaskQuery {

    # Runs a POST .../query against the given entity and follows pageDetails.nextPageUrl
    # until exhausted, returning every item across all pages. Per Autotask's paging
    # contract, each subsequent page is fetched by POSTing the SAME request body to
    # nextPageUrl (a GET, or an empty body, both fail) - confirmed against the live API.

    [CmdletBinding()]

    param(
        [Parameter(Mandatory)] $Connection,
        [Parameter(Mandatory)] [string]$Entity,

        # Array of filter condition hashtables, e.g. @(@{op="noteq";field="status";value=5})
        [Parameter(Mandatory)] [array]$Filter,

        [int]$MaxRecords = 500,

        # Stop after the first page instead of following nextPageUrl to exhaustion -
        # for smoke tests/spot checks where the full result set isn't needed.
        [switch]$FirstPageOnly
    )

    $BodyObject = @{ MaxRecords = $MaxRecords; filter = $Filter }
    $BodyJson = $BodyObject | ConvertTo-Json -Depth 10 -Compress

    $Items = [System.Collections.Generic.List[object]]::new()
    $Uri = "$($Connection.ZoneUrl)v1.0/$Entity/query"

    while ($Uri) {
        $Content = New-Object System.Net.Http.StringContent($BodyJson, [System.Text.Encoding]::UTF8, "application/json")
        $Response = $Connection.Client.PostAsync($Uri, $Content).GetAwaiter().GetResult()
        $ResponseBody = $Response.Content.ReadAsStringAsync().GetAwaiter().GetResult()

        if (-not $Response.IsSuccessStatusCode) {
            throw "Autotask query failed for $Entity ($Uri) - HTTP $([int]$Response.StatusCode): $ResponseBody"
        }

        $Parsed = $ResponseBody | ConvertFrom-Json
        foreach ($item in $Parsed.items) { $Items.Add($item) }
        $Uri = if ($FirstPageOnly) { $null } else { $Parsed.pageDetails.nextPageUrl }
    }

    return $Items
}

function Get-AutotaskPicklist {

    # Returns the picklist value->label map (a hashtable keyed by the string value) for
    # a given field on a given entity, e.g. Get-AutotaskPicklist $conn "Projects" "status".

    [CmdletBinding()]

    param(
        [Parameter(Mandatory)] $Connection,
        [Parameter(Mandatory)] [string]$Entity,
        [Parameter(Mandatory)] [string]$FieldName
    )

    $Uri = "$($Connection.ZoneUrl)v1.0/$Entity/entityInformation/fields"
    $Response = $Connection.Client.GetAsync($Uri).GetAwaiter().GetResult()
    $ResponseBody = $Response.Content.ReadAsStringAsync().GetAwaiter().GetResult()

    if (-not $Response.IsSuccessStatusCode) {
        throw "Failed to fetch field metadata for $Entity - HTTP $([int]$Response.StatusCode): $ResponseBody"
    }

    $Parsed = $ResponseBody | ConvertFrom-Json
    $Field = $Parsed.fields | Where-Object { $_.name -eq $FieldName }
    if (-not $Field) { throw "Field '$FieldName' not found on entity '$Entity'." }
    if (-not $Field.isPickList) { throw "Field '$FieldName' on entity '$Entity' is not a picklist." }

    $Map = @{}
    foreach ($v in $Field.picklistValues) { $Map[$v.value] = $v.label }
    return $Map
}
