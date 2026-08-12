################################################################################################################### 
##
## This script conducts a site access review in Teams and disables inactive sites
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
    [int]$LessThanDays,
    [switch]$LogExclusions,
    [switch]$Testing,
    
    # Output options

    [switch]$Logging,
    [string[]]$ToEmailAddr
    
)

# System settings and variables

$Date = Get-Date -Format yyyy-MM-dd
$CountTeams = 0
$CountExclusions = 0
$CountResults = 0
$CountErrors = 0
$CountDisabled = 0
$i = 0
$GroupsHt = @{}
$Results = @()

# Derived settings and variables

$BasePath = "C:\PS\$Directory"
$SettingsPath = Join-Path $BasePath "Settings\CustomerSettings.txt"
$LogFile = Join-Path $BasePath "Logs\SiteAuditTeams-Disable.csv"

# Import functions

. "C:\PS\Scripts\VA-Functions.ps1"

#Start processing

$StartTime = Get-Date

# Import settings and acquire token

$CustomerSettings = Import-CustomerSettings -SettingsPath $SettingsPath
$Token = Get-GraphToken -CustomerSettings $CustomerSettings
$Headers = @{ Authorization = "Bearer $Token" }

# Get groups, page results and build a hashtable for reference later

$Uri = "https://graph.microsoft.com/v1.0/groups?`$select=DisplayName,Mail,Id,CreatedDateTime" 
$Groups = Get-AllResults -Uri $Uri -Headers $Headers

foreach ($Group in $Groups) { $GroupsHt[$Group.id] = $Group }

# Get activity and convert CSV results to a PowerShell object 

$Uri = "https://graph.microsoft.com/v1.0/reports/getTeamsTeamActivityDetail(period='D180')" 
$Teams = Invoke-RestMethod -Uri $Uri -Headers $Headers | ConvertFrom-Csv -Delimiter ','

# Filter the list of Teams

$DateCutoff = ($StartTime.AddDays(-$LessThanDays)).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$Teams = foreach ($Team in $Teams) {

    if ($Team."Is Deleted" -eq $true) { continue }
    if ($Team."Last Activity Date" -gt $DateCutoff) { continue }

    $Team

} 
$CountTeams = @($Teams).count

# Analyze activity

$Results = foreach ($Team in $Teams) {

    $i++

    Write-Progress -activity "Processing..." -status "$i out of $CountTeams completed" -PercentComplete ([int](($i/$CountTeams)*100))

    # Identify exclusions
    
    $MicrosoftTeam = $GroupsHt[$Team."Team Id"]
    if ($MicrosoftTeam.createdDateTime -ge $DateCutoff) { continue }

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
            Mail              = $MicrosoftTeam.Mail
            CreatedDate       = $MicrosoftTeam.CreatedDateTime
            LastActivityDate  = $LastActivityDate
            DaysAgo           = $DaysAgo
            Issue             = if (-not $InExclusion) {"Last activity more than $LessThanDays days ago"} else {$null}
            Action            = if (-not $InExclusion) {"Disable team"} else {$null}
            ActionTaken       = $null

        }
        
        if ($LogExclusions) { $Finding.InExclusionGroup = if ($InExclusion) {"Y"} else {$null} }

        [PSCustomObject]$Finding

        $CountResults++

    }

}       
            
# For testing, announce what would have happened

if ($Testing -eq $true) {
    
    foreach ($Result in $Results) { if ($Result.Action -eq "Disable team") { Write-Host "Testing Mode:" $Result.TeamName"would be disabled." } }

# For execution, take the appropriate action

} else {

    foreach ($Result in $Results) {

    # Disable the team
    
    $Result.ActionTaken = "Disabled team"
    Write-Host $Result.SiteName"was disabled."

    }

}

#End processing

$EndTime = Get-Date
$TotalTime = ($EndTime-$StartTime).TotalSeconds
$Minutes = "{0:N0}" -f ($TotalTime/60)
$Seconds = "{0:N0}" -f ($TotalTime%60)

Write-Host "`r`nAudit conducted on Teams sites in $Minutes minutes and $Seconds seconds.`r`n"

Write-Host "$CountResults enabled teams(s) audited."
Write-Host "$CountExclusions team(s) in exclusion groups."
Write-Host "$CountErrors error(s) encountered."
Write-Host "$CountDisabled team(s) disabled."

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
     
        if ($Testing -eq $true) { $Body="<b><i>Testing Mode</i></b><br>" } else { $Body="" }

        if ($Results) { $Body+= "CSV Attached for $Date<br>" } else { $Body+= "No CSV Attached for $Date - No Results<br>" }
    
        $Body+="

        Audit conducted on Teams sites in $Minutes minutes and $Seconds seconds.<br>
        <br>
        $CountResults enabled teams(s) audited.<br>
        $CountExclusions team(s) in exclusion groups.<br>
        $CountErrors error(s) encountered.<br>
        $CountDisabled team(s) disabled.<br>
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
        $Subject     = "Teams Site Audit - $LessThanDays Days Inactive"
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