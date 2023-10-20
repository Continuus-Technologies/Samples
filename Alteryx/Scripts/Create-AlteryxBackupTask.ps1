#requires -RunAsAdministrator
<#
.SYNOPSIS
    PowerShell Script to configure the Alteryx Server MongoDB Backup Task
.DESCRIPTION
    This script will prompt the user for the credentials of the service
    account that the Scheduled Task will use when it runs the Backup-AlteryxServer
    script. Next it will lookup the Security Identifier (SID) of the service
    account and grant it permission to 'Log On as a Batch Job' in the Local
    Security Policy.
.PARAMETER scriptPath
    The path to the the script.
    Defaults to ['C:\ProgramData\Alteryx\Backup-AlteryxServer.ps1']
.PARAMETER description
    The description of the scheduled task.
.PARAMETER taskPath
    The folder in Task Scheduler where the task will be created.
    Defaults to ['\Alteryx']
.EXAMPLE
    Create-AlteryxBackupTask.ps1
    This example uses a the default backup script location. ['C:\ProgramData\Alteryx\Backup-AlteryxServer.ps1']
.EXAMPLE
    Create-AlteryxBackupTask.ps1 [[-scriptPath] 'E:\ProgramData\Alteryx\Backup-AlteryxServer.ps1']
    This example uses a non-default backup script location.
.NOTES
    Author: Comrad Kite
            Continuus Technologies
    Date:   06/2023

    Maintenance Window Considerations: This script assumes that the Alteryx
        server has a nightly maintenance window when workflows aren't scheduled.
        This script also assumes that backups are run on weeknights at 11pm.
        The schedule can be adjusted in the lines following the param block.

    Security Considerations: This script will need to be run from a PowerShell
        console that is running as an Administrator. The reason the Administrator
        permission is required is because we will be modifying the Local
        Security Policy and creating a Scheduled Task.

        The service account that will run the Alteryx backup script must
        be a local Administrator as well. The reason the account requires
        the permission is because it needs to be able to stop the Alteryx
        service. There may be a way to granularly grant the service account
        permission to control the Alteryx service, but that is beyond the
        scope of this script.

        Additionally, the service account will need permission to write to
        the local backup destination ['C:\Temp'] and to the archive destination
        ['\\SERVER\Share\AlteryxBackups'] on the remote file server.

        If the service account password is set to expire the Alteryx backup
        Scheduled Task will need to be updated when the password changes.
        It's probably easier to do it from the Task Scheduler management
        console, but here's the code to do it from PowerShell:
        
            $credential = Get-Credential -Message "Provide credential for account that will run the backup script"
            $task = Get-ScheduledTask -TaskName 'Backup-AlteryxServer' -TaskPath '\Alteryx'
            $task | Set-ScheduledTask -User $credential.GetNetworkCredential().UserName -Password $credential.GetNetworkCredential().Password

    Attribution: The functions used for exporting and importing the Local
        Secruity Policy were drawn from the following post.
        
        https://stackoverflow.com/questions/23260656/modify-local-security-policy-using-powershell/55776100#55776100

#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $false,
        HelpMessage = "The path to the script.")]
    [string]$scriptPath = "C:\ProgramData\Alteryx\Backup-AlteryxServer.ps1",
    [Parameter(Mandatory = $false,
        HelpMessage = "The description of the scheduled task.")]
    [string]$description = "Stops Alteryx and creates a backup of the database before restarting Alteryx. It then copies the backup to a compressed file on a remote file share.",
    [ValidateScript({$_.StartsWith("\")})]
    [Parameter(Mandatory = $false,
        HelpMessage = "The folder in Task Scheduler where the task will be created.")]
        [string]$taskPath = "\Alteryx"
)

# # Schedule the backup here # #
#
# # Weeknights
$taskTrigger = New-ScheduledTaskTrigger -Weekly -WeeksInterval 1 -DaysOfWeek @('Monday','Tuesday','Wednesday','Thursday','Friday') -At 11pm


# # Nightly
# $TaskTrigger = New-ScheduledTaskTrigger -Daily -DaysInterval 1 -At 11pm

# Register the security policy functions
Function Get-SecPol($CfgFile) { 
    secedit /export /cfg "$CfgFile" /areas USER_RIGHTS | Out-Null
    $obj = New-Object psobject
    $index = 0
    $contents = Get-Content $CfgFile -Raw
    [regex]::Matches($contents, "(?<=\[)(.*)(?=\])") | ForEach-Object {
        $title = $_
        [regex]::Matches($contents, "(?<=\]).*?((?=\[)|(\Z))", [System.Text.RegularExpressions.RegexOptions]::Singleline)[$index] | ForEach-Object {
            $section = New-Object psobject
            $_.Value -Split "\r\n" | Where-Object { $_.length -gt 0 } | ForEach-Object {
                $value = [regex]::Match($_, "(?<=\=).*").Value
                $name = [regex]::Match($_, ".*(?=\=)").Value
                $section | Add-Member -MemberType NoteProperty -Name $name.ToString().Trim() -Value $value.ToString().Trim() -ErrorAction SilentlyContinue | Out-Null
            }
            $obj | Add-Member -MemberType NoteProperty -Name $title -Value $section
        }
        $index += 1
    }
    return $obj
}
Function Set-SecPol($Object, $CfgFile) {
    $Object.psobject.Properties.GetEnumerator() | ForEach-Object {
        "[$($_.Name)]"
        $_.Value | ForEach-Object {
            $_.psobject.Properties.GetEnumerator() | ForEach-Object {
                "$($_.Name)=$($_.Value)"
            }
        }
    } | Out-File $CfgFile -ErrorAction Stop
    secedit /import /db batchlogon.sdb /cfg "$CfgFile"
    secedit /configure /db batchlogon.sdb /cfg "$CfgFile" /areas USER_RIGHTS
}

# Set the working directory
$workingDir = "C:\Temp"
if (!(Test-Path $workingDir)) {
    try {
        $null = New-Item -ItemType directory -Path $workingDir -ErrorAction Stop
        Write-Output "The working directory, $workingDir, was created automatically"
    }
    catch {
        Write-Output "The working directory, $workingDir, is inaccessible. Check path."
    }
}
Set-Location $workingDir

# For security reasons, prompt for the credential so it isn't saved to disk
# This also prevents the password from appearing if someone runs [Get-History]
$credential = Get-Credential -Message "Provide credential for account that will run the backup script"
if ($credential.GetNetworkCredential().Domain.Length -gt 0) {
    $username = $credential.GetNetworkCredential().Domain + '\' + $credential.GetNetworkCredential().UserName    
}
else {
    $username = $credential.GetNetworkCredential().UserName
}
# Now that we have the account, we can look up the SID
# We'll need this when we update the local security policy
Write-Verbose "Looking up Security Identifier (SID) for $username" -Verbose
$account = New-Object -Type System.Security.Principal.NTAccount -Argument $username
$SID = $account.Translate([System.Security.Principal.SecurityIdentifier]).Value

# The following commands will fail if this is not run as an Administrator
# Now we need to export a copy of the local security policy
$secPol = Get-SecPol -CfgFile C:\Temp\secpol.inf
# Get the current setting for Batch Logon Right and append the SID to the end of it
$seBatchLogonRight = $secPol.'Privilege Rights'.SeBatchLogonRight
$secPol.'Privilege Rights'.SeBatchLogonRight = $seBatchLogonRight + ',*' + $SID
# Now we'll import the updated local security policy
Set-SecPol -Object $secPol -CfgFile C:\Temp\secpol.inf
# ...and delete the export containing the sensitive settings
Remove-Item C:\Temp\secpol.inf -Force

# The argument allow PowerShell to run our script in the background
$argument = '-ExecutionPolicy Bypass -NoProfile -NonInteractive -File "' + $scriptPath + '"'
$taskAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument  $argument
$taskName = ($scriptPath.Split('\') | Select-Object -Last 1).Split('.') | Select-Object -First 1
# Define the service account that will run the task
$taskPrincipal = New-ScheduledTaskPrincipal -Id $credential.UserName -UserId $username -LogonType Password -RunLevel Highest
# Build the scheduled task from the pieces above
$task = New-ScheduledTask -Description $description -Action $taskAction -Principal $taskPrincipal -Trigger $taskTrigger
# And securely set the password for the task when we register it
Write-Verbose "Registering Scheduled Task" -Verbose
$task = $task | Register-ScheduledTask -TaskName $taskName -TaskPath $taskPath -User $username -Password $credential.GetNetworkCredential().Password

Write-Verbose "Script completed" -Verbose
