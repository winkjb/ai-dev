################################################################################################################### 
##
## This script audits M365 license usage details
## Version 2.5
##
################################################################################################################### 

param(

    # Search and analysis variables

    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$Directory,
    [string]$CustomerFolder,
    [string[]]$ExcludedLicenses,
    [switch]$LogExclusions,
   
    # Output options

    [switch]$Logging,
    [string[]]$ToEmailAddr
    
)

# System settings and variables

$Date = Get-Date -Format yyyy-MM-dd
$CountLicenses = 0
$CountUsers = 0
$CountResults = 0
$i = 0
$CountExclusions = 0
$UserHt = @{}
$UserHtBySku = @{}
$UserLicense = @()
$LicensedUsers = @()
$Results = @()

# Derived settings and variables

$BasePath = "C:\PS\$Directory"
$SettingsPath = Join-Path $BasePath "Settings\CustomerSettings.txt"
$LogFile = Join-Path $BasePath "Logs\EntraLicenseAudit-UsageDetail.csv"

# Import functions

. "C:\PS\Scripts\VA-Functions.ps1"

# Start processing

$StartTime = Get-Date

# Import settings and acquire token

$CustomerSettings = Import-CustomerSettings -SettingsPath $SettingsPath
$Token = Get-GraphToken -CustomerSettings $CustomerSettings
$Headers = @{ Authorization = "Bearer $Token" }

# Get licenses and page results

$Uri = "https://graph.microsoft.com/v1.0/subscribedSkus"
$Licenses = Get-AllResults -Uri $Uri -Headers $Headers
$CountLicenses = @($Licenses).count

# Get users, page results and build hashtables for reference later

$Uri = "https://graph.microsoft.com/beta/users?`$select=displayName,userPrincipalName,assignedLicenses,createdDateTime"
$Users = Get-AllResults -Uri $Uri -Headers $Headers

foreach ($User in $Users) { 

    # User > user info
    $UserHt[$User.UserPrincipalName] = $User

    # Sku > users
    foreach ($AssignedLicense in $User.AssignedLicenses) {
        $SkuId = $AssignedLicense.SkuId
        Add-ToIndex -Index $UserHtBySku -Key $SkuId -Value $User
    }

}
$CountUsers = @($Users).Count

# Audit licenses 

$Results = foreach ($License in $Licenses) {

    $i++

    Write-Progress -activity "Processing..." -status "$i out of $CountLicenses completed" -PercentComplete ([int](($i/$CountLicenses)*100))

    # Get license usage

    $UserLicense = Get-FriendlyLicenseName -sku $License.skuPartNumber
    $SkuId = $License.SkuId
    
    if ($UserHtBySku.ContainsKey($SkuId)) {
        $LicensedUsers = $UserHtBySku[$SkuId]
    } else {
        $LicensedUsers = @()
    }

    # Identify exclusions

    $InExclusion = $ExcludedLicenses -contains $License.skuPartNumber
    
    if ($InExclusion) { $CountExclusions++ }

    # Log finding

    if (-not $InExclusion -or $LogExclusions) {

        foreach ($LicensedUser in $LicensedUsers) {
            
            # Normalize details

            $CreatedDate = $LicensedUser.createdDateTime
            $DaysAgo = Get-DaysSince $CreatedDate

            # Normalize finding

            $Finding = [ordered] @{ 
        
                Date         = $Date
                DisplayName  = $LicensedUser.DisplayName
                UPN          = $LicensedUser.UserPrincipalName
                UserLicense  = $UserLicense
                CreatedDate  = $CreatedDate
                DaysAgo      = $DaysAgo
            
            }

            if ($LogExclusions) { $Finding.InExclusionGroup = if ($InExclusion) {"Y"} else {$null} }

            [PSCustomObject]$Finding

        }

    $CountResults++

    }

}

# End processing

$EndTime = Get-Date
$TotalTime = ($EndTime-$StartTime).TotalSeconds
$Minutes = "{0:N0}" -f ($TotalTime/60)
$Seconds = "{0:N0}" -f ($TotalTime%60)

Write-Host "`r`nAudit conducted on Entra license details in $Minutes minutes and $Seconds seconds.`r`n"

Write-Host "$CountLicenses license(s) audited."
Write-Host "$CountExclusions license(s) excluded."
Write-Host "$CountResults license(s) expanded."

# Log results

if ($Logging -eq $true) {

    if ($LogFile) {

        # Export log file

        Ensure-Directory ($LogFile)
        $Results | Sort-Object DisplayName,UserLicense | Export-CSV -Path $LogFile -NoTypeInformation 
        Write-Host "CSV File created at $LogFile.`r`n"
    
    }

    if ($ToEmailAddr) {

        # Email the CSV and stats to admin(s)

        $Body=""

        if ($Results) { $Body+= "CSV Attached for $Date<br>" } else { $Body+="No CSV Attached for $Date - No Results<br>" }

        $Body+="

        Audit conducted on Entra license details in $Minutes minutes and $Seconds seconds.<br>
        <br>
        $CountLicenses license(s) audited.<br>
        $CountExclusions license(s) excluded.<br>
        $CountResults license(s) expanded.<br>
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
        $Subject     = "Entra License Audit - Detail"
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