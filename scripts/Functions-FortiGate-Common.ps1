###################################################################################################################
##
## This script contains FortiGate REST API functions for dot sourcing
## Version 1.0
##
###################################################################################################################

function Connect-FortiGate {

    [CmdletBinding()]

    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$CustomerSettings
    )

    if (-not $CustomerSettings.Address -or -not $CustomerSettings.ApiKey) {
        throw "FortiGate settings missing Address or ApiKey."
    }

    $IsPS7Plus = $PSVersionTable.PSVersion.Major -ge 7

    # PS5.1 has no -SkipCertificateCheck on Invoke-RestMethod - only way to reach a
    # FortiGate's self-signed admin cert is a process-wide cert-validation override.
    if (-not $IsPS7Plus -and -not ("TrustAllCertsPolicy" -as [type])) {
        Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(
        ServicePoint srvPoint, X509Certificate certificate,
        WebRequest request, int certificateProblem) {
        return true;
    }
}
"@
        [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    }

    return [PSCustomObject]@{
        BaseUrl   = "https://$($CustomerSettings.Address)/api/v2"
        Headers   = @{ Authorization = "Bearer $($CustomerSettings.ApiKey)" }
        Vdom      = $CustomerSettings.Vdom
        IsPS7Plus = $IsPS7Plus
    }
}

function Invoke-FGTApi {

    [CmdletBinding()]

    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Context,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $Uri = "$($Context.BaseUrl)/$Path"
    if (-not [string]::IsNullOrWhiteSpace($Context.Vdom)) {
        $Uri += if ($Uri -match '\?') { "&vdom=$($Context.Vdom)" } else { "?vdom=$($Context.Vdom)" }
    }

    try {
        if ($Context.IsPS7Plus) {
            return Invoke-RestMethod -Uri $Uri -Headers $Context.Headers -Method Get -SkipCertificateCheck -ErrorAction Stop
        }
        else {
            return Invoke-RestMethod -Uri $Uri -Headers $Context.Headers -Method Get -ErrorAction Stop
        }
    }
    catch {
        throw "FortiGate API call failed for $Uri`: $($_.Exception.Message)"
    }
}
