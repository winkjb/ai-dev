###################################################################################################################
##
## Shared BOM-safe text/CSV writers, used by coordinator report scripts across teams (project-management,
## service-delivery). Windows PowerShell 5.1's -Encoding UTF8 always writes a BOM; the retired Python (pandas)
## report versions never did, so these keep report output byte-for-byte consistent with that history.
##
###################################################################################################################

function Set-Utf8NoBomContent {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Value
    )

    [System.IO.File]::WriteAllText($Path, $Value, [System.Text.UTF8Encoding]::new($false))
}

function Export-Utf8NoBomCsv {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [array]$InputObject
    )

    $Csv = $InputObject | ConvertTo-Csv -NoTypeInformation
    Set-Utf8NoBomContent -Path $Path -Value (($Csv -join "`r`n") + "`r`n")
}
