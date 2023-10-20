#requires -RunAsAdministrator
<#
.SYNOPSIS
    Alteryx Server Backup - Worker Management PowerShell Script
.DESCRIPTION
    Stops the Alteryx service prior to the backup window
.PARAMETER dest
    The path the local logs will be created in.
    Defaults to [C:\Temp\Alteryx]
.PARAMETER retention
    The number of days the logs will be stored.
    By default, this is set to 1
.EXAMPLE
    Stop-AlteryxService [[-dest] E:\AlteryxLogs]
    This example uses a non-default destination
.NOTES
    Author: Comrad Kite
            Continuus Technologies
    Date:   07/2023
#>
param (
    [Parameter(Mandatory = $false,
        HelpMessage = "The path the logs will be created in.")]
    [string]$dest = "C:\Temp\Alteryx",
    [Parameter(Mandatory = $false,
        HelpMessage = "The number of days to retain backup logs.")]
    [string]$retention = '1'
)

if (!(Test-Path $dest)) {
    try {
        New-Item -ItemType directory -Path $dest -ErrorAction Stop
        Write-Output "The log path, $dest, was created automatically"
    }
    catch {
        Write-Output "The log path, $dest, is inaccessible. Check path."
    }
}


$logdate = Get-Date -Format yyyy-MM-dd-HH-mm
[string]$log = $dest + "\BackupLog-" + $logdate + ".csv"

function SendOutput() {
    param (
        [string]
        $output
    )

    $Now = Get-Date -Format "MM/dd/yyyy HH:mm:ss"
    # Build a hashtable of the collected data + computername, faster than arrays
    $Properties = @{ComputerName = $env:COMPUTERNAME
        Now                      = $Now | Out-String
        Output                   = $Output | Out-String
    }

    $Object = New-Object -TypeName PSObject -Property $Properties
    Write-Output $Object | Select-Object -Property Now, ComputerName, Output | Export-Csv -Path $log -NoTypeInformation -Append
    Write-Output $Object | Select-Object -Property Output | ConvertTo-CSV | Write-Host -ForegroundColor Magenta
}

$Output = 'Beginning backup script'; SendOutput -Output $Output

# Stop and disable service to ensure MongoDB will be offline
Write-Warning "Stopping AlteryxService.exe"
Set-Service -ServiceName AlteryxService -StartupType Disabled
Stop-Service AlteryxService | Out-Null

# Wait for the service to stop
[int]$i = 0
[string]$processname = "AlteryxService"
$process = Get-Process -Name $processname -ErrorAction SilentlyContinue
if (!($process)) {
    Write-Host "$processname stopped" -ForegroundColor Green 
}
if ($process) {
    Write-Host "$processname is still running" -ForegroundColor Yellow 
    Write-Verbose "$processname PID $($process.Id)" -Verbose
}
while ($process) {
    if ($process.HasExited) {
        Write-Host "$processname has stopped" -ForegroundColor Green
        break 
    }
    Write-Host "Pausing for 30 seconds"
    Start-Sleep -Seconds 30
    $process = Get-Process -Name $processname
    if ($i -ge 20) {
        # If this has been waiting 10 minutes, it will try to force stop the Alteryx service
        Write-Verbose "Waited >20 attempts, attempting to force stop" -Verbose
        Stop-Process -Force $process 
    }
    if ($i -ge 22) {
        # Force stopping the service has failed, terminate script, manual intervention required.
        Write-Warning "Detected runaway loop"
        break
    }
    Write-Host "Attempt $i"
    $i++
    Stop-Process $process
} # end while $process

# Clean up the logs based on lastwrite filter and file name filter
$logFiles = Get-Childitem $dest -File -Filter "BackupLog-*.csv" | Where-Object { $_.LastWriteTime -lt "$lastWrite" }
if ($logFiles -ne $null) {
    foreach ($logFile in $logFiles) {
        $Output = "Removing log $logFile"; SendOutput -Output $Output
        Remove-Item -Path $logFile.FullName -Recurse -Force
    }
}