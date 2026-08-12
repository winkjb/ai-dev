################################################################################################################### 
##
## This script conducts a site access review in SharePoint and disables inactive sites
## Version 2.5
##
###################################################################################################################

param(

    # Search and analysis variables

    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$Directory,
    [string]$CustomerFolder,
    [string[]]$ExcludedSites,
    [int]$LessThanDays,
    [switch]$LogExclusions,
    [switch]$Testing,
    
    # Output options

    [switch]$Logging,
    [string[]]$ToEmailAddr
    
)

# System settings and variables

$Date = Get-Date -Format yyyy-MM-dd
$CountSites = 0
$CountExclusions = 0
$CountResults = 0
$CountErrors = 0
$CountDisabled = 0
$i = 0
$TeamsHt = @{}
$SitesHt = @{}
$Results = @()

# Derived settings and variables

$BasePath = "C:\PS\$Directory"
$SettingsPath = Join-Path $BasePath "Settings\CustomerSettings.txt"
$LogFile = Join-Path $BasePath "Logs\SiteAuditSharePoint-Disable.csv"

# Import functions

. "C:\PS\Scripts\VA-Functions.ps1"

#Start processing

$StartTime = Get-Date

# Import settings and acquire token

$CustomerSettings = Import-CustomerSettings -SettingsPath $SettingsPath
$Token = Get-GraphToken -CustomerSettings $CustomerSettings
$Headers = @{ Authorization = "Bearer $Token" }

# Get groups, page results and build a hashtable for reference later

$Uri = "https://graph.microsoft.com/v1.0/groups?`$select=DisplayName,Mail,Id,CreatedDateTime,ResourceProvisioningOptions" 
$Teams = Get-AllResults -Uri $Uri -Headers $Headers 

foreach ($Team in $Teams) { if ($Team.ResourceProvisioningOptions) { $TeamsHt[$Team.displayName] = $Team } }

# Get sites, page results and build a hashtable for reference later

$Uri = "https://graph.microsoft.com/v1.0/sites?`$select=DisplayName,WebUrl,Id,CreatedDateTime,isPersonalSite" 
$Sites = Get-AllResults -Uri $Uri -Headers $Headers

foreach ($Site in $Sites) { if (-not $Site.isPersonalSite) { $SitesHt[(($Site.id -split ',')[1])] = $Site } }

# Get activity and convert results to a PowerShell object

$Uri = "https://graph.microsoft.com/v1.0/reports/getSharePointSiteUsageDetail(period='D180')" 
$Sites = Invoke-RestMethod -Uri $Uri -Headers $Headers | ConvertFrom-Csv -Delimiter ','

# Filter the list of sites

$DateCutoff = ($StartTime.AddDays(-$LessThanDays)).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$Sites = foreach ($Site in $Sites) {

    if ($Site."Is Deleted" -eq $true) { continue }
    if ( ($Site."Root Web Template" -eq "Team Channel") -or ($Site."Root Web Template" -like "* Search Center") ) { continue }
    if ($Site."Last Activity Date" -gt $DateCutoff) { continue }
    
    $Site

} 
$CountSites = @($Sites).count

# Analyze activity

$Results = foreach ($Site in $Sites) {

    $i++

    Write-Progress -activity "Processing..." -status "$i out of $CountSites completed" -PercentComplete ([int](($i/$CountSites)*100))
    
    # Identify exclusions

    $SharePointSite = $SitesHt[$Site."Site Id"]
    if (-not $SharePointSite) { continue }
    if ($SharePointSite.createdDateTime -ge $DateCutoff) { continue }
    
    $MicrosoftTeam = $TeamsHt[$SharePointSite.displayName] 
    
    $InExclusion = ($MicrosoftTeam -or $ExcludedSites -contains $SharePointSite.displayName)
    
    if ($InExclusion) { $CountExclusions++ }

    # Log finding

    if (-not $InExclusion -or $LogExclusions) {

        # Normalize activity

        $StorageUsedGb = [math]::Round($Site.'Storage Used (Byte)' / 1000000000, 2)
        $FileCount = $Site."File Count"
        $LastActivityDate = $Site."Last Activity Date"
        $DaysAgo = Get-DaysSince $LastActivityDate

        # Normalize finding

        $Finding = [ordered] @{ 
            
            Date              = $Date
            SiteName          = $SharePointSite.displayName
            WebUrl            = $SharePointSite.WebUrl
            CreatedDate       = $SharePointSite.CreatedDateTime
            FileCount         = $FileCount
            StorageUsedGb     = $StorageUsedGb
            LastActivityDate  = $LastActivityDate
            DaysAgo           = $DaysAgo
            Issue             = if (-not $InExclusion) {"Last activity more than $LessThanDays days ago"} else {$null}
            Action            = if (-not $InExclusion) {"Disable site"} else {$null}
            ActionTaken       = $null 

        }
   
        if ($LogExclusions) { $Finding.InExclusionGroup = if ($InExclusion) {"Y"} else {$null} }

        [PSCustomObject]$Finding

        $CountResults++

    }

}

# For testing, announce what would have happened

if ($Testing -eq $true) {
    
    foreach ($Result in $Results) { if ($Result.Action -eq "Disable site") { Write-Host "Testing Mode:" $Result.SiteName"would be disabled." } }

# For execution, take the appropriate action

} else {

    foreach ($Result in $Results) {

    # Disable the site
    
    $Result.ActionTaken = "Disabled site"
    Write-Host $Result.SiteName"was disabled."

    }

}

#End processing

$EndTime = Get-Date
$TotalTime = ($EndTime-$StartTime).TotalSeconds
$Minutes = "{0:N0}" -f ($TotalTime/60)
$Seconds = "{0:N0}" -f ($TotalTime%60)

Write-Host "`r`nAudit conducted on SharePoint sites in $Minutes minutes and $Seconds seconds.`r`n"

Write-Host "$CountSites enabled site(s) audited."
Write-Host "$CountExclusions site(s) in exclusion groups."
Write-Host "$CountErrors error(s) encountered."
Write-Host "$CountDisabled site(s) disabled."

# Log results

if ($Logging -eq $true) {

    if ($LogFile) { 

        # Export log file

        Ensure-Directory ($LogFile)
        $Results | Sort-Object SiteName | Export-CSV -Path $LogFile -NoTypeInformation 
        Write-Host "CSV File created at $LogFile.`r`n"

    }
    
    if ($ToEmailAddr) {

        #Email the CSV and stats to admin(s) 

        if ($Testing -eq $true) { $Body="<b><i>Testing Mode</i></b><br>" } else { $Body="" }

        if ($Results) { $Body+= "CSV Attached for $Date<br>" } else { $Body+= "No CSV Attached for $Date - No Results<br>" }
    
        $Body+="

        Audit conducted on SharePoint sites in $Minutes minutes and $Seconds seconds.<br>
        <br>
        $CountSites enabled site(s) audited.<br>
        $CountExclusions site(s) in exclusion groups.<br>
        $CountErrors error(s) encountered.<br>
        $CountDisabled site(s) disabled.<br>
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
        $Subject     = "SharePoint Site Audit - $LessThanDays Days Inactive"
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