#requires -RunAsAdministrator
<#
.SYNOPSIS
    Alteryx Server Backup - Worker Management PowerShell Script
.DESCRIPTION
    Starts the Alteryx service at the end of the backup window
.PARAMETER dest
    The path the local logs will be created in.
    Defaults to [C:\Temp\Alteryx]
.PARAMETER retention
    The number of days the logs will be stored.
    By default, this is set to 1
.EXAMPLE
    Start-AlteryxService [[-dest] E:\AlteryxLogs]
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
# Restarting the Alteryx service
Set-Service -ServiceName AlteryxService -StartupType Automatic
$output = "Starting Alteryx Service"; SendOutput -Output $Output
Start-Service AlteryxService | Out-Null
$output = "Starting Alteryx Service exit code: $lastexitcode"; SendOutput -Output $Output

# Define lastWriteTime based on $retention
$lastWrite = (Get-Date).AddDays(-$retention)

# Clean up the logs based on lastwrite filter and file name filter
$logFiles = Get-Childitem $dest -File -Filter "BackupLog-*.csv" | Where-Object { $_.LastWriteTime -lt "$lastWrite" }
if ($logFiles -ne $null) {
    foreach ($logFile in $logFiles) {
        $Output = "Removing log $logFile"; SendOutput -Output $Output
        Remove-Item -Path $logFile.FullName -Recurse -Force
    }
}