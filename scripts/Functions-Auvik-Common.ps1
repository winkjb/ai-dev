################################################################################################################### 
##
## This script contains shared Auvik functions to dot source
## Version 1.0
##
###################################################################################################################

function Set-AuvikApiContext {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [array]$Settings
    )

    try {
        $Username = $Settings.Username
        $ApiKey = $Settings.ApiKey
        $Region = $Settings.Region

        $b64Creds = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($Username):$($ApiKey)"))
        $Headers = @{
            Authorization  = "Basic $b64Creds"
            "Content-Type" = "application/json"
        }

        $BaseUri = "https://auvikapi.$Region.my.auvik.com/v1"

        return [PSCustomObject]@{
            Headers  = $Headers
            BaseUri  = $BaseUri
        }
    }
    catch {
        throw "Set-AuvikApiContext failed: $($_.Exception.Message)"
    }

}

function Invoke-AuvikApiRequest {

    param(
        [string]$Uri,
        [hashtable]$Headers
    )

    try {
        $Response = Invoke-RestMethod -Uri $Uri -Headers $Headers -Method Get -ErrorAction Stop
        Start-Sleep -Milliseconds $ThrottleMs
        return $Response
    }
    catch {
        Write-Warning "Request failed: $Uri`n$($_.Exception.Message)"
        Start-Sleep -Milliseconds $ThrottleMs
        return $null
    }

}

function Get-AllAuvikResults {

    param(
        [string]$InitialUri,
        [hashtable]$Headers
    )

    $AllAuvikResults = [System.Collections.Generic.List[object]]::new()
    $Uri = $InitialUri

    while ($Uri) {
        $Resp = Invoke-AuvikApiRequest -Uri $Uri -Headers $Headers
        if (-not $resp) { break }

        if ($resp.data) {
            foreach ($item in $resp.data) { $AllAuvikResults.Add($item) }
        }

        # Auvik uses JSON:API style pagination links
        $Uri = $Resp.links.next
    }

    return $AllAuvikResults

}