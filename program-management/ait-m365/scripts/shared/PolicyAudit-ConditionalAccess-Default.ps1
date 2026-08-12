################################################################################################################### 
##
## This script conducts an audit of Conditional Access Policies
## Version 2.5
##
###################################################################################################################

param(

    # Search and analysis variables

    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$Directory,
    [string]$CustomerFolder,
    [switch]$ExcludeMsPolicies,
    
    # Output options

    [switch]$Logging,
    [string[]]$ToEmailAddr
    
)


# System settings and variables

$Date = Get-Date -Format yyyy-MM-dd
$CountPolicies = 0
$CountExclusions = 0
$CountResults = 0
$i = 0
$UserAndGroupHt = @{}
$RoleHt = @{}
$Results = @()

# Derived settings and variables

$BasePath = "C:\PS\$Directory"
$SettingsPath = Join-Path $BasePath "Settings\CustomerSettings.txt"
$LogFile = Join-Path $BasePath "Logs\EntraPolicyAudit-ConditionalAccess.csv"

# Import functions

. "C:\PS\Scripts\VA-Functions.ps1"

# Start processing

$StartTime = Get-Date

# Import settings and acquire token

$CustomerSettings = Import-CustomerSettings -SettingsPath $SettingsPath
$Token = Get-GraphToken -CustomerSettings $CustomerSettings
$Headers = @{ Authorization = "Bearer $Token" }

# Get users, page results and create a hashtable for reference later

$Uri = "https://graph.microsoft.com/v1.0/users?`$select=id,displayName"
$Users = Get-AllResults -Uri $Uri -Headers $Headers

foreach ($User in $Users) { $UserAndGroupHt[$User.id] = $User.DisplayName }

# Get groups, page results and update the hashtable for reference later

$Uri = "https://graph.microsoft.com/v1.0/groups?`$select=id,displayName"
$Groups = Get-AllResults -Uri $Uri -Headers $Headers

foreach ($Group in $Groups) { $UserAndGroupHt[$Group.id] = $Group.DisplayName }

# Get admin roles, page results and create a hashtable for reference later

$Uri = "https://graph.microsoft.com/beta/roleManagement/directory/roleDefinitions?`$select=id,displayName"
$Roles = Get-AllResults -Uri $Uri -Headers $Headers

foreach ($Role in $Roles) { $RoleHt[$Role.Id] = $Role.DisplayName }

# Get policies and page results

$Uri = "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies?`$select=displayName,templateId,state,conditions"
$Policies = Get-AllResults -Uri $Uri -Headers $Headers
$CountPolicies = @($Policies).Count

# Audit policies

$Results = foreach ($Policy in $Policies) {

    $i++

    Write-Progress -activity "Processing..." -status "$i out of $CountPolicies completed" -PercentComplete ([int](($i/$CountPolicies)*100))

    # Identify exclusions
    
    $InExclusion = ($Policy.templateId -and $Policy.State -eq "disabled")
    
    if ($InExclusion) { 
    
        $CountExclusions++
    
        if ($ExcludeMsPolicies) { continue } 
     
    }
        
    # Normalize policy details

    $Guids = $Policy.Conditions.users.includeUsers
    if ($Guids -eq "All") { $IncludedUsers = "All"
    } else { $IncludedUsers = ($UserAndGroupHt[$Guids] | Sort-Object) -join ', ' }
   
    $Guids = $Policy.Conditions.users.excludeUsers
    $ExcludedUsers = ($UserAndGroupHt[$Guids] | Sort-Object) -join ', '
    
    $Guids = $Policy.Conditions.users.includeRoles
    if (-not $Guids) { $IncludedRoles = $null
    } else { $IncludedRoles = ($RoleHt[$Guids] | Sort-Object) -join ', ' }
   
    $Guids = $Policy.Conditions.users.excludeRoles
    if (-not $Guids) { $ExcludedRoles = $null
    } else { $ExcludedRoles = ($RoleHt[$Guids] | Sort-Object) -join ', ' }
   
    $Guids = $Policy.Conditions.users.includeGroups
    $IncludedGroups = ($UserAndGroupHt[$Guids] | Sort-Object) -join ', '
    
    $Guids = $Policy.Conditions.users.excludeGroups
    $ExcludedGroups = ($UserAndGroupHt[$Guids] | Sort-Object) -join ', '
    
    # Log finding

    [PSCustomObject][ordered] @{ 
        
        Date             = $Date
        DisplayName      = $Policy.DisplayName
        State            = $Policy.State
        IncludedUsers    = $IncludedUsers
        ExcludedUsers    = $ExcludedUsers
        IncludedRoles    = $IncludedRoles
        ExcludedRoles    = $ExcludedRoles
        IncludedGroups   = $IncludedGroups
        ExcludedGroups   = $ExcludedGroups 
        
    }

    $CountResults++ 
    
}

# End processing

$EndTime = Get-Date
$TotalTime = ($EndTime-$StartTime).TotalSeconds
$Minutes = "{0:N0}" -f ($TotalTime/60)
$Seconds = "{0:N0}" -f ($TotalTime%60)

Write-Host "`r`nAudit conducted on Entra ID tenant conditional access policies in $Minutes minutes and $Seconds seconds.`r`n"

Write-Host "$CountPolicies policy(s) audited."
Write-Host "$CountExclusions policy(s) excluded."
Write-Host "$CountResults result(s) identified."

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

        $Body = ""
    
        if ($Results) { $Body+= "CSV Attached for $Date<br>" } else { $Body+="No CSV Attached for $Date - No Results<br>" }

        $Body+="  
        Audit conducted on Entra ID policies in $Minutes minutes and $Seconds seconds.<br>
        <br>
        $CountPolicies policy(s) audited.<br>
        $CountExclusions policy(s) excluded.<br>
        $CountResults result(s) identified.<br>
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
        $Subject     = "Entra Conditional Access Policy Audit"
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