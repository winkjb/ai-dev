################################################################################################################### 
##
## This script audits user activities in Entra ID
## Version 2.5
##
################################################################################################################### 

param(

    # Search and analysis variables

    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$Directory,
    [string]$CustomerFolder,
    [int]$LookBackDays,
    [int]$Top,
   
    # Output options

    [switch]$Logging,
    [string[]]$ToEmailAddr
    
)

# System settings and variables

$Date = Get-Date -Format yyyy-MM-dd
$Script:CountRecords = 0
$Script:CountEvents = 0
$CountEvents = 0

# Derived settings and variables

$BasePath = "C:\PS\$Directory"
$SettingsPath = Join-Path $BasePath "Settings\CustomerSettings.txt"
$LogFile = Join-Path $BasePath "Logs\EntraLogAudit-UserActivities.csv"

# Import functions

. "C:\PS\Scripts\VA-Functions.ps1"

# Define additional functions

function Get-NewUri {
    param(
        [datetime]$StartUtc,
        [datetime]$EndUtc,
        [int]$Top
    )

    $Start = $StartUtc.ToString("s") + "Z"
    $End   = $EndUtc.ToString("s") + "Z"

    return "https://graph.microsoft.com/beta/auditLogs/directoryAudits?`$filter=activityDateTime ge $Start and activityDateTime lt $End&`$orderby=activityDateTime desc&`$top=$Top"
}

function Write-ActivityRecords {
    param(
        $Events,
        [string]$LogFile,
        [string]$Date,
        [bool]$Logging
    )

    foreach ($Event in @($Events)) {

        $Script:CountEvents++
        if ($Script:CountEvents % 250 -eq 0) { Write-Progress -Activity "Processing..." -Status "$Script:CountEvents events completed" }

        $InitiatedBy =
            if ($Event.initiatedBy.user.displayName) {
                $Event.initiatedBy.user.displayName
            }
            elseif ($Event.initiatedBy.app.displayName) {
                $Event.initiatedBy.app.displayName
            }
            else {
                $null
            }

        $Targets = @($Event.targetResources)

        if ($Targets.Count -eq 0) {
            $Targets = @(
                [PSCustomObject]@{
                    id                 = $null
                    displayName        = $null
                    type               = $null
                    userPrincipalName  = $null
                    modifiedProperties = @()
                }
            )
        }

        foreach ($Target in $Targets) {

            $TargetId = $Target.id
            $TargetDisplayName = $Target.displayName
            $TargetType = $Target.type
            $TargetUPN = $Target.userPrincipalName
            $ModifiedProperties = @($Target.modifiedProperties)
            $AdditionalDetails = (@($Event.additionalDetails) | ForEach-Object {
                "$($_.key): $($_.value)"
            }) -join "; "

            if ($ModifiedProperties.Count -gt 0) {
                foreach ($Property in $ModifiedProperties) {
                    $Record = [PSCustomObject][ordered]@{
                        Date                = $Date
                        ActivityDateTime    = $Event.activityDateTime
                        ActivityDisplayName = $Event.activityDisplayName
                        EventId             = $Event.id
                        InitiatedBy         = $InitiatedBy
                        Category            = $Event.category
                        CorrelationId       = $Event.correlationId
                        LoggedByService     = $Event.loggedByService
                        OperationType       = $Event.operationType
                        Result              = $Event.result
                        TargetId            = $TargetId
                        TargetDisplayName   = $TargetDisplayName
                        TargetType          = $TargetType
                        TargetUPN           = $TargetUPN
                        ModifiedProperty    = $Property.displayName
                        OldValue            = $Property.oldValue
                        NewValue            = $Property.newValue
                        AdditionalDetails   = $AdditionalDetails
                        UserAgent           = $Event.userAgent
                    }

                    if ($Logging) {
                        Write-IncrementalCsv -Path $LogFile -InputObject $Record
                    }

                    $Script:CountRecords++
                }
            }
            else {
                $Record = [PSCustomObject][ordered]@{
                    Date                = $Date
                    ActivityDateTime    = $Event.activityDateTime
                    ActivityDisplayName = $Event.activityDisplayName
                    EventId             = $Event.id
                    InitiatedBy         = $InitiatedBy
                    Category            = $Event.category
                    CorrelationId       = $Event.correlationId
                    LoggedByService     = $Event.loggedByService
                    OperationType       = $Event.operationType
                    Result              = $Event.result
                    TargetId            = $TargetId
                    TargetDisplayName   = $TargetDisplayName
                    TargetType          = $TargetType
                    TargetUPN           = $TargetUPN
                    ModifiedProperty    = $null
                    OldValue            = $null
                    NewValue            = $null
                    AdditionalDetails   = $AdditionalDetails
                    UserAgent           = $Event.userAgent
                }

                if ($Logging) {
                    Write-IncrementalCsv -Path $LogFile -InputObject $Record
                }

                $Script:CountRecords++
            }
        }
    }
}

function Get-Activities {
    param(
        [datetime]$StartUtc,
        [datetime]$EndUtc,
        [int]$Top,
        [PSCustomObject]$CustomerSettings,
        [string]$LogFile,
        [string]$Date,
        [bool]$Logging
    )

    $SliceEventCount = 0
    $Uri = Get-NewUri -StartUtc $StartUtc -EndUtc $EndUtc -Top $Top

    $Headers = @{ Authorization = "Bearer $(Get-GraphToken -CustomerSettings $CustomerSettings)" }
    $Response = Invoke-GraphRequest -Url $Uri -Headers $Headers

    while ($true) {

        $Events = @($Response.value)

        if ($Events.Count -gt 0) {
            Write-ActivityRecords -Events $Events -LogFile $LogFile -Date $Date -Logging $Logging
            $SliceEventCount += $Events.Count
        }

        if (-not $Response.'@odata.nextLink') {
            break
        }

        $Headers = @{ Authorization = "Bearer $(Get-GraphToken -CustomerSettings $CustomerSettings)" }
        $Response = Invoke-GraphRequest -Url $Response.'@odata.nextLink' -Headers $Headers
    }

    return $SliceEventCount
}
        
# Start processing

$StartTime = Get-Date
if ($Logging -and (Test-Path -LiteralPath $LogFile)) { Remove-Item -LiteralPath $LogFile -Force }

# Import settings

$CustomerSettings = Import-CustomerSettings -SettingsPath $SettingsPath

# Create start and end times

$EndUtc   = (Get-Date).ToUniversalTime()
$StartUtc = $EndUtc.AddDays(-$LookBackDays)

# Get events in daily slices

$Cursor = $EndUtc

while ($Cursor -gt $StartUtc) {

    $SliceStart = $Cursor.AddDays(-1)

    if ($SliceStart -lt $StartUtc) {
        $SliceStart = $StartUtc
    }

    try {
        $SliceCount = Get-Activities -StartUtc $SliceStart -EndUtc $Cursor -Top $Top -CustomerSettings $CustomerSettings -LogFile $LogFile -Date $Date -Logging $Logging
        $CountEvents += $SliceCount
    }
    catch {
        Write-Host ("Slice {0} -> {1} failed: {2}" -f $SliceStart.ToString("s"), $Cursor.ToString("s"), $_.Exception.Message) -ForegroundColor Yellow
    }

    $Cursor = $SliceStart
}

# Exception if there are no events

if ($Script:CountRecords -eq 0) {

    $NoDataRecord = [PSCustomObject][ordered]@{
        Date                = $Date
        ActivityDateTime    = $null
        ActivityDisplayName = $null
        EventId             = $null
        InitiatedBy         = $null
        Category            = $null
        CorrelationId       = $null
        LoggedByService     = $null
        OperationType       = $null
        Result              = $null
        TargetId            = $null
        TargetDisplayName   = $null
        TargetType          = $null
        TargetUPN           = $null
        ModifiedProperty    = $null
        OldValue            = $null
        NewValue            = $null
        AdditionalDetails   = "No user activities between $($StartUtc.ToString('s')) and $($EndUtc.ToString('s')) (UTC)"
        UserAgent           = $null
    }

    if ($Logging) {
        Write-IncrementalCsv -Path $LogFile -InputObject $NoDataRecord
    }
}

$EndTime = Get-Date
$TotalTime = ($EndTime - $StartTime).TotalSeconds
$Minutes = "{0:N0}" -f ($TotalTime / 60)
$Seconds = "{0:N0}" -f ($TotalTime % 60)

Write-Host "`r`nAudit conducted on Entra user activities in $Minutes minutes and $Seconds seconds.`r`n"
Write-Host "$CountEvents event(s) fetched from Entra."
Write-Host "$Script:CountRecords event record(s) processed."

# Log results

if ($Logging -eq $true) {

    if ($LogFile) {

        # Export log file
        Write-Host "$Script:CountRecords event record(s) written to CSV at $LogFile.`r`n"
    
    }

    if ($ToEmailAddr) {

        # Check file and file size
        
        $HasRecords = $Script:CountRecords -gt 0
        $MaxSizeMB = 30
        $FileSizeMB = (Get-Item $LogFile).Length / 1MB
        if ($HasRecords -and $FileSizeMB -le $MaxSizeMB) { $Attachment = $LogFile } else { $Attachment = $null }
        
        # Email the CSV and stats to admin(s)

        $Body = ""
    
        if ($HasRecords) {
    
            if ($FileSizeMB -gt $MaxSizeMB) { $Body += "No CSV Attached for $Date - Too Large ($([math]::Round($FileSizeMB, 2)) MB)<br>"
            } else { $Body += "CSV Attached for $Date<br>" }

        } else { $Body += "No CSV Attached for $Date - No Results<br>" }

        $Body+="  

        Audit conducted on Entra user activities in $Minutes minutes and $Seconds seconds.<br>
        <br>
        $CountEvents event(s) fetched from Entra.<br>
        $Script:CountRecords event(s) written to CSV.<br>
        <br>
        <br>
        ##############################<br>
        Source: Virtual Administrator<br>
        Customer Folder: $CustomerFolder<br>
        ##############################<br>
        "

        # Format the email parameters

        $SmtpServer  = $CustomerSettings.SmtpServer
        $Port        = $CustomerSettings.SmtpPort
        $From        = $CustomerSettings.SmtpFrom
        $To          = $ToEmailAddr
        $Subject     = "Entra User Activity Audit"
        $Body        = $Body
        $UseSsl      = $CustomerSettings.SmtpSsl -eq "Yes"

        if ( ($CustomerSettings.SmtpUsername -ne "") -and ($CustomerSettings.SmtpPassword -ne "") ) { 
    
            $SmtpPassword = ConvertTo-SecureString $CustomerSettings.SmtpPassword -AsPlainText -Force
            $Credentials = New-Object System.Management.Automation.PSCredential($CustomerSettings.SmtpUsername, $SmtpPassword)

        } else {

           $Credentials = $null 

        }

        # Send the email

        Send-Results -SmtpServer $SmtpServer -Port $Port -From $From -To $To -Subject $Subject -Body $Body -BodyAsHtml $true -UseSsl $UseSsl -Credential $Credentials -Attachment $Attachment

    }

}