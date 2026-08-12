################################################################################################################### 
##
## This script audits user sign-ins in Entra ID
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
    [switch]$ReportOnly,
   
    # Output options

    [switch]$Logging,
    [string[]]$ToEmailAddr
    
)

# System settings and variables

$Date = Get-Date -Format yyyy-MM-dd
$Script:CountWritten = 0
$Script:CountFetched = 0
$Script:EventIndex = 0

# Derived settings and variables

$BasePath = "C:\PS\$Directory"
$SettingsPath = Join-Path $BasePath "Settings\CustomerSettings.txt"
$LogFile = Join-Path $BasePath "Logs\EntraLogAudit-UserSignIns.csv"

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

    "https://graph.microsoft.com/beta/auditLogs/signIns?`$filter=createdDateTime ge $Start and createdDateTime lt $End&`$orderby=createdDateTime desc&`$top=$Top"
}

function Convert-ObjectPropertiesToString {
    param($InputObject)

    if (-not $InputObject) { return "" }

    ($InputObject.PSObject.Properties | ForEach-Object {
        "$($_.Name): $($_.Value)"
    }) -join "; "
}

function Convert-PolicyDetailsToString {
    param($Policies)

    if (-not $Policies) { return "" }

    ($Policies | ForEach-Object {
        "ID: $($_.id); " +
        "DisplayName: $($_.displayName); " +
        "Result: $($_.result); " +
        "ConditionsNotSatisfied: $($_.conditionsNotSatisfied -join ', '); " +
        "SessionControlsNotSatisfied: $($_.sessionControlsNotSatisfied -join ', ')"
    }) -join "`n"
}

function Convert-NetworkLocationDetailsToString {
    param($NetworkLocationDetails)

    if (-not $NetworkLocationDetails) { return "" }

    ($NetworkLocationDetails | ForEach-Object {
        $Detail = $_
        ($Detail.PSObject.Properties | ForEach-Object {
            "$($_.Name): $($_.Value)"
        }) -join "; "
    }) -join "`n"
}

function Convert-AuthenticationDetailsToString {
    param($AuthenticationDetails)

    if (-not $AuthenticationDetails) { return "" }

    ($AuthenticationDetails | ForEach-Object {
        "AuthenticationStepDateTime: $($_.authenticationStepDateTime); " +
        "AuthenticationMethod: $($_.authenticationMethod); " +
        "AuthenticationMethodDetail: $($_.authenticationMethodDetail); " +
        "Succeeded: $($_.succeeded); " +
        "AuthenticationStepResultDetail: $($_.authenticationStepResultDetail); " +
        "AuthenticationStepRequirement: $($_.authenticationStepRequirement);"
    }) -join "`n"
}

function Get-MatchingPolicies {
    param($Event)

    if (-not $Event.appliedConditionalAccessPolicies) { return @() }

    if ($ReportOnly) {
        $ResultsToMatch = @(
            'reportOnlySuccess',
            'reportOnlyFailure',
            'reportOnlyNotApplied'
        )

        return @(
            $Event.appliedConditionalAccessPolicies |
            Where-Object { $_.result -in $ResultsToMatch }
        )
    }

    return @($Event.appliedConditionalAccessPolicies)
}

function Process-SignInEvents {
    param(
        [array]$Events,
        [string]$LogFile
    )

    foreach ($Event in $Events) {

        $Script:EventIndex++

        if (($Script:EventIndex % 250) -eq 0) { Write-Progress -Activity "Processing..." -Status "$Script:EventIndex events completed" }

        $MatchingPolicies = Get-MatchingPolicies -Event $Event
        if ($ReportOnly -and @($MatchingPolicies).Count -eq 0) { continue }

        $Record = [PSCustomObject][ordered]@{
            Date                             = $Date
            CreatedDateTime                  = $Event.createdDateTime
            UserDisplayName                  = $Event.userDisplayName
            UserPrincipalName                = $Event.userPrincipalName
            AppId                            = $Event.appId
            AppDisplayName                   = $Event.appDisplayName
            IpAddress                        = $Event.ipAddress
            ClientApp                        = $Event.clientAppUsed
            UserAgent                        = $Event.userAgent
            CorrelationId                    = $Event.correlationId
            IsInteractive                    = $Event.isInteractive
            AuthenticationRequirement        = $Event.authenticationRequirement
            EventStatus                      = Convert-ObjectPropertiesToString -InputObject $Event.status
            DeviceDetail                     = Convert-ObjectPropertiesToString -InputObject $Event.deviceDetail
            Location                         = Convert-ObjectPropertiesToString -InputObject $Event.location
            ConditionalAccessStatus          = $Event.conditionalAccessStatus
            AppliedConditionalAccessPolicies = Convert-PolicyDetailsToString -Policies $MatchingPolicies
            NetworkLocationDetails           = Convert-NetworkLocationDetailsToString -NetworkLocationDetails $Event.networkLocationDetails
            AuthenticationDetails            = Convert-AuthenticationDetailsToString -AuthenticationDetails $Event.authenticationDetails
        }

        Write-IncrementalCsv -Path $LogFile -InputObject $Record
        $Script:CountWritten++
    }
}

function Get-SignIns {
    param(
        [datetime]$StartUtc,
        [datetime]$EndUtc,
        [int]$Top,
        $CustomerSettings,
        [string]$LogFile
    )

    $Uri = Get-NewUri -StartUtc $StartUtc -EndUtc $EndUtc -Top $Top

    do {
        $Headers = @{ Authorization = "Bearer " + (Get-GraphToken -CustomerSettings $CustomerSettings) }
        $Response = Invoke-GraphRequest -Url $Uri -Headers $Headers

        $Events = @($Response.value)
        if ($Events.Count -gt 0) {
            $Script:CountFetched += $Events.Count
            Process-SignInEvents -Events $Events -LogFile $LogFile
        }

        $Uri = $Response.'@odata.nextLink'
    }
    while ($Uri)
}

# Start processing

$StartTime = Get-Date

if (Test-Path -LiteralPath $LogFile) {
    Remove-Item -LiteralPath $LogFile -Force
}

# Import settings

$CustomerSettings = Import-CustomerSettings -SettingsPath $SettingsPath

# Create start and end times 

$EndUtc   = (Get-Date).ToUniversalTime()
$StartUtc = $EndUtc.AddDays(-$LookBackDays)

# Get events in daily slices

$Cursor = $EndUtc

while ($Cursor -gt $StartUtc) {

    $SliceStart = $Cursor.AddDays(-1)
    if ($SliceStart -lt $StartUtc) { $SliceStart = $StartUtc }

    try {
        Get-SignIns -StartUtc $SliceStart -EndUtc $Cursor -Top $Top -CustomerSettings $CustomerSettings -LogFile $LogFile
    }
    catch {
        Write-Host ("Slice {0} -> {1} failed: {2}" -f $SliceStart.ToString("s"), $Cursor.ToString("s"), $_.Exception.Message) -ForegroundColor Yellow
    }

    $Cursor = $SliceStart
}

# Exception if there are no events written

if ($Script:CountWritten -eq 0) {

    $NoDataRecord = [PSCustomObject][ordered]@{
        Date                             = $Date
        CreatedDateTime                  = $null
        UserDisplayName                  = $null
        UserPrincipalName                = $null
        AppId                            = $null
        AppDisplayName                   = $null
        IpAddress                        = $null
        ClientApp                        = $null
        UserAgent                        = $null
        CorrelationId                    = $null
        IsInteractive                    = $null
        AuthenticationRequirement        = $null
        EventStatus                      = "No sign-in events between $($StartUtc.ToString('s')) and $($EndUtc.ToString('s')) (UTC)"
        DeviceDetail                     = $null
        Location                         = $null
        ConditionalAccessStatus          = $null
        AppliedConditionalAccessPolicies = $null
        NetworkLocationDetails           = $null
        AuthenticationDetails            = $null
    }

    Write-IncrementalCsv -Path $LogFile -InputObject $NoDataRecord
}

$EndTime = Get-Date
$TotalTime = ($EndTime - $StartTime).TotalSeconds
$Minutes = "{0:N0}" -f ($TotalTime / 60)
$Seconds = "{0:N0}" -f ($TotalTime % 60)

Write-Host "`r`nAudit conducted on Entra user sign-ins in $Minutes minutes and $Seconds seconds.`r`n"
Write-Host "$Script:CountFetched event(s) fetched from Entra."
Write-Host "$Script:CountWritten event(s) written to CSV."

# Log results

if ($Logging -eq $true) {

    if ($LogFile) {

        # Export log file
        Write-Host "CSV File created at $LogFile.`r`n"
    
    }

    if ($ToEmailAddr) {

        # Check file and file size
        
        $HasRecords = $Script:CountWritten -gt 0
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
      
        Audit conducted on Entra sign-ins in $Minutes minutes and $Seconds seconds.<br>
        <br>
        $Script:CountFetched event(s) fetched from Entra.<br>
        $Script:CountWritten event(s) written to CSV.<br>
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
        $Subject     = "Entra User Sign-in Audit"
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