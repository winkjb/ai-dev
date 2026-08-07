<#
.SYNOPSIS
    
.EXAMPLE
    .\Invoke-PowerDmarcReports.ps1
#>

[CmdletBinding()]
param()

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

# System settings and variables

$OutputDir = Join-Path $PSScriptRoot ".\output"
$OutputFile = Join-Path $OutputDir ("run-logs-{0:yyyy-MM}.log" -f (Get-Date))

# Import functions

. (Join-Path $PSScriptRoot "..\..\scripts\Functions-VA-Common.ps1")
$EmailScript = Join-Path $PSScriptRoot "..\..\scripts\Send-EmailMessage.ps1"

# ---------------------------------------------------------------------------
# Run tasks  
# ---------------------------------------------------------------------------

# Script settings and variables

$ErrorActionPreference = "Stop"

# Validate output directory

Test-Directory $OutputDir

# Run tasks

try {

    # ---------------------------------------------------------------------------
    # Beginning tasks
    # ---------------------------------------------------------------------------

    Write-ToLog -LogFile $OutputFile -Message "=== Starting runs ==="

    & (Join-Path $PSScriptRoot "Export-BillableDomains.ps1")
    Write-ToLog -LogFile $OutputFile -Message "Generated PowerDMARC reports"

    # ---------------------------------------------------------------------------
    # Email 1: Format and send email results
    # ---------------------------------------------------------------------------
        
    $ToAddresses = @("bwinklesky@servit.net")
    $Attachments = @(
        Join-Path $OutputDir "billable-domains-summary.csv"
        Join-Path $OutputDir "billable-domains-detail.csv"
    )

    & $EmailScript -To $ToAddresses -Subject "PowerDMARC Reports" -Attachments $Attachments
    Write-ToLog -LogFile $OutputFile -Message "Emailed reports to $($ToAddresses -join ', ')"
    
    # ---------------------------------------------------------------------------
    # Ending tasks
    # ---------------------------------------------------------------------------

    Write-ToLog -LogFile $OutputFile -Message "=== Run completed successfully ==="

}
catch {

    Write-ToLog -LogFile $OutputFile -Message "ERROR: $($_.Exception.Message)" -Level ERROR
    Write-ToLog -LogFile $OutputFile -Message "=== Run failed ===" -Level ERROR

    # Best-effort failure notice - if this fails too (e.g. SMTP settings themselves are the
    # problem), don't let that mask the original error's exit code.
    try {
        & $EmailScript -To $ToAddresses -Subject "PowerDMARC Reports - FAILED" `
            -Body "The report run failed: $($_.Exception.Message)`n`nSee $OutputFile on the host machine for details."
    }
    catch {
        Write-ToLog -LogFile $OutputFile -Message "Also failed to send failure notification: $($_.Exception.Message)" -Level ERROR
    }

    exit 1

}
