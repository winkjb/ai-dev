################################################################################################################### 
##
## This script conducts an activity audit in Teams
## Version 2.5
##
###################################################################################################################

param(

    # Search and analysis variables

    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$Directory,
    [string]$CustomerFolder,
    [string[]]$ExcludedTeams,
    [int]$ReportingDays,
    [switch]$LogExclusions,
    
    # Output options

    [switch]$Logging,
    [string[]]$ToEmailAddr
    
)

# System settings and variables

$Date = Get-Date -Format yyyy-MM-dd
$CountTeams = 0
$CountExclusions = 0
$CountResults = 0
$i = 0
$GroupsHt = @{}
$Results = @()

# Derived settings and variables

$BasePath = "C:\PS\$Directory"
$SettingsPath = Join-Path $BasePath "Settings\CustomerSettings.txt"
$LogFile = Join-Path $BasePath "Logs\SiteAuditTeams-Activity.csv"

# Import functions

. "C:\PS\Scripts\VA-Functions.ps1"

# Start processing

$StartTime = Get-Date

# Import settings and acquire token

$CustomerSettings = Import-CustomerSettings -SettingsPath $SettingsPath
$Token = Get-GraphToken -CustomerSettings $CustomerSettings
$Headers = @{ Authorization = "Bearer $Token" }

# Get groups, page results and build 

$Uri = "https://graph.microsoft.com/v1.0/groups?`$select=DisplayName,Mail,Id,CreatedDateTime" 
$Groups = Get-AllResults -Uri $Uri -Headers $Headers

foreach ($Group in $Groups) { $GroupsHt[$Group.id] = $Group }

# Get activity and convert CSV results to a PowerShell object 

$Uri = "https://graph.microsoft.com/v1.0/reports/getTeamsTeamActivityDetail(period='D$ReportingDays')" 
$Teams = Invoke-RestMethod -Uri $Uri -Headers $Headers | ConvertFrom-Csv -Delimiter ','

# Filter the list of Teams

$Teams = foreach ($Team in $Teams) {

    if ($Team."Is Deleted" -eq $true) { continue }
    
    $Team

} 
$CountTeams = @($Teams).count

# Capture activity

$Results = foreach ($Team in $Teams) {

    $i++

    Write-Progress -activity "Processing..." -status "$i out of $CountTeams completed" -PercentComplete ([int](($i/$CountTeams)*100))

    # Identify exclusions
    
    $MicrosoftTeam = $GroupsHt[$Team."Team Id"]
      
    $InExclusion = $ExcludedTeams -contains $MicrosoftTeam.displayName
    
    if ($InExclusion) { $CountExclusions++ }

    # Log finding

    if (-not $InExclusion -or $LogExclusions) {

        # Normalize activity

        $LastActivityDate = $Team."Last Activity Date"
        $DaysAgo = Get-DaysSince $LastActivityDate

        # Normalize finding

        $Finding = [ordered] @{ 
            
            Date              = $Date
            TeamName          = $Team."Team Name"
            ActiveUsers       = $Team."Active Users"
            ActiveChannels    = $Team."Active Channels"
            PostMessages      = $Team."Post Messages"
            ReplyMessages     = $Team."Reply Messages"
            CreatedDate       = $MicrosoftTeam.CreatedDateTime 
            LastActivityDate  = $LastActivityDate
            DaysAgo           = $DaysAgo

        }

        if ($LogExclusions) { $Finding.InExclusionGroup = if ($InExclusion) {"Y"} else {$null} }

        [PSCustomObject]$Finding

        $CountResults++

    }

}

#End processing

$EndTime = Get-Date
$TotalTime = ($EndTime-$StartTime).TotalSeconds
$Minutes = "{0:N0}" -f ($TotalTime/60)
$Seconds = "{0:N0}" -f ($TotalTime%60)

Write-Host "`r`nAudit conducted on Teams sites in $Minutes minutes and $Seconds seconds.`r`n"

Write-Host "$CountTeams enabled teams(s) audited."
Write-Host "$CountExclusions team(s) in exclusion groups."
Write-Host "$CountResults team(s) identified."

# Log results

if ($Logging -eq $true) {

    if ($LogFile) { 

        # Export log file

        Ensure-Directory ($LogFile)
        $Results | Sort-Object TeamName | Export-CSV -Path $LogFile -NoTypeInformation 
        Write-Host "CSV File created at $LogFile.`r`n"

    }
    
    if ($ToEmailAddr) {

        #Email the CSV and stats to admin(s)
     
        $Body=""

        if ($Results) { $Body+= "CSV Attached for $Date<br>" } else { $Body+= "No CSV Attached for $Date - No Results<br>" }
    
        $Body+="

        Audit conducted on Teams sites in $Minutes minutes and $Seconds seconds.<br>
        <br>
        $CountResults enabled teams(s) audited.<br>
        $CountExclusions team(s) in exclusion groups.<br>
        $CountResults team(s) identified.<br>
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
        $Subject     = "Teams Site Activity Audit - $ReportingDays Days"
        $Body        = $Body
        $UseSsl      = $CustomerSettings.SmtpSsl -eq "Yes"

        if ($Results) { $Attachment = $LogFile } else { $Attachment = $null }
       
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