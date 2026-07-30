################################################################################################################### 
##
## This script contains common/shared Auvik functions to dot source
## Version 1.0
##
###################################################################################################################

function Invoke-AuvikRequest {
    param(
        [string]$Uri
    )
    try {
        $response = Invoke-RestMethod -Uri $Uri -Headers $Headers -Method Get -ErrorAction Stop
        Start-Sleep -Milliseconds $ThrottleMs
        return $response
    }
    catch {
        Write-Warning "Request failed: $Uri`n$($_.Exception.Message)"
        Start-Sleep -Milliseconds $ThrottleMs
        return $null
    }
}

function Get-AllPages {
    param(
        [string]$InitialUri
    )
    $allResults = [System.Collections.Generic.List[object]]::new()
    $uri = $InitialUri

    while ($uri) {
        $resp = Invoke-AuvikRequest -Uri $uri
        if (-not $resp) { break }

        if ($resp.data) {
            foreach ($item in $resp.data) { $allResults.Add($item) }
        }

        # Auvik uses JSON:API style pagination links
        $uri = $resp.links.next
    }

    return $allResults
}