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

        # AllowEmptyString - same binder gotcha as Export-Utf8NoBomCsv's AllowEmptyCollection:
        # a Mandatory [string] rejects "" outright otherwise, which mattered once
        # Export-Utf8NoBomCsv started deliberately passing "" for zero-result runs.
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Value
    )

    [System.IO.File]::WriteAllText($Path, $Value, [System.Text.UTF8Encoding]::new($false))
}

function Export-Utf8NoBomCsv {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,

        # AllowEmptyCollection - without it, PowerShell's binder rejects an empty array for a
        # Mandatory array parameter before the function body ever runs ("Cannot bind argument
        # to parameter 'InputObject' because it is an empty collection"), which would otherwise
        # crash every caller the moment a real run legitimately finds zero results.
        [Parameter(Mandatory)] [AllowEmptyCollection()] [array]$InputObject
    )

    if ($InputObject.Count -eq 0) {
        # No objects means no property names to derive a header from - write a genuinely empty
        # file rather than a stray blank line, so a zero-result run still leaves a real (if
        # header-less) file at $Path for callers/email attachments that expect one to exist.
        Set-Utf8NoBomContent -Path $Path -Value ""
        return
    }

    $Csv = $InputObject | ConvertTo-Csv -NoTypeInformation
    Set-Utf8NoBomContent -Path $Path -Value (($Csv -join "`r`n") + "`r`n")
}
