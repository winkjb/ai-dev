################################################################################################################### 
##
## This script looks for Entra groups that appear to be temporary
## Version 2.5
##
################################################################################################################### 

param(

    # Search and analysis variables

    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$Directory,
    [string]$CustomerFolder,
    [string[]]$ExcludedGroups,
    [switch]$LogExclusions,
   
    # Output options

    [switch]$Logging,
    [string[]]$ToEmailAddr
    
)

# System settings and variables

$Date = Get-Date -Format yyyy-MM-dd
$CountGroups = 0
$CountExclusions = 0
$CountResults = 0
$i = 0
$Results = @()

# Derived settings and variables

#$BasePath = "..\..\$Directory"
$BasePath = "..\..\katz"
$SettingsPath = Join-Path $BasePath "Settings\CustomerSettings.txt"
$LogFile = Join-Path $BasePath "Logs\EntraGroupAudit-TempGroups.csv"

# Import functions

. (Join-Path $PSScriptRoot "..\..\..\..\scripts\Functions-VA-Common.ps1")

# Start processing

$StartTime = Get-Date

# Import settings and acquire token

$CustomerSettings = Import-Settings -SettingsPath $SettingsPath
$Token = Get-GraphToken -CustomerSettings $CustomerSettings
$Headers = @{ Authorization = "Bearer $Token" }

# Get groups and page results

$Uri = "https://graph.microsoft.com/v1.0/groups?`$select=displayName,mail,createdDateTime,groupTypes"
$Groups = Get-AllResults -Uri $Uri -Headers $Headers

# Filter the list of groups

$Groups = $Groups.Where({ (($_.DisplayName -like "*test*") -or ($_.DisplayName -like "*temp*") -or ($_.UserPrincipalName -like "*test*") -or ($_.UserPrincipalName -like "*temp*")) -and ($_.DisplayName -notlike "*Templates*") })
$CountGroups = $Groups.Count

# Audit groups

$Results = foreach ($Group in $Groups) {
    
    $i++

    Write-Progress -activity "Processing..." -Status "$i out of $CountGroups completed" -PercentComplete ([int](($i/$CountGroups)*100))

    # Identify exclusions

    $InExclusion = ( ($ExcludedGroups -contains $Group.DisplayName) -or ($ExcludedGroups -contains $Group.mail) )
    
    if ($InExclusion) { $CountExclusions++ }

    # Log finding
    
    if (-not $InExclusion -or $LogExclusions) {
    
        # Normalize details

        $CreatedDate = $Group.createdDateTime
        $DaysAgo = Get-DaysSince $CreatedDate

        # Normalize finding

        $Finding = [ordered]@{

            Date         = $Date
            DisplayName  = $Group.DisplayName
            Email        = $Group.mail
            CreatedDate  = $CreatedDate
            DaysAgo      = $DaysAgo 
            GroupType    = $Group.groupTypes -join ","
            
        }
        
        if ($LogExclusions) { $Finding.InExclusionGroup = if ($InExclusion) {"Y"} else {$null} }

        [PSCustomObject]$Finding

        $CountResults++ 

    }

}

# End processing

$EndTime = Get-Date
$TotalTime = ($EndTime-$StartTime).TotalSeconds
$Minutes = "{0:N0}" -f ($TotalTime/60)
$Seconds = "{0:N0}" -f ($TotalTime%60)

Write-Host "`r`nAudit conducted on Entra groups in $Minutes minutes and $Seconds seconds.`r`n"

Write-Host "$CountGroups temp group(s) audited."
Write-Host "$CountExclusions group(s) excluded."
Write-Host "$CountResults temp group(s) identified."

# Log results

if ($Logging -eq $true) {

    if ($LogFile) {

        # Export log file

        Ensure-Directory ($LogFile)
        $Results | Sort-Object DisplayName | Export-CSV -Path $LogFile -NoTypeInformation 
        Write-Host "CSV File created at $LogFile.`r`n"

    }

    if ($ToEmailAddr) {
    
        # Email the CSV and stats to admin(s)

        $Body=""

        if ($Results) { $Body+= "CSV Attached for $Date<br>" } else { $Body+="No CSV Attached for $Date - No Results<br>" }

        $Body+="

        Audit conducted on Entra groups in $Minutes minutes and $Seconds seconds.<br>
        <br>
        $CountGroups temp group(s) audited.<br>
        $CountExclusions group(s) excluded.<br>
        $CountResults temp group(s) identified.<br>
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
        $Subject     = "Entra Group Audit - Temp Groups"
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