#requires -RunAsAdministrator
<#
.SYNOPSIS
    Alteryx Server Backup - Worker Management PowerShell Script
.DESCRIPTION
    The task watches (queries) the API and waits to start the service until
    it responds with a HTTP 200 OK message. 
.PARAMETER uri
    The Alteryx API URL that will be watched by this script.
    Should look something like https://sever.domain.com/webapi/swagger/ui/index
.PARAMETER dest
    The path the local logs will be created in.
    Defaults to [C:\Temp\Alteryx]
.PARAMETER retention
    The number of days the logs will be stored.
    By default, this is set to 1
.EXAMPLE
    Watch-AlteryxBackup [[-dest] E:\AlteryxLogs] [[-uri] http://another.example.com/webapi/swagger/ui/index]
    This example uses a non-default destination
.NOTES
    Author: Comrad Kite
            Continuus Technologies
    Date:   06/2023

    Maintenance Window Considerations:
        The Alteryx service must be stopped to perform a backup of the MongoDB. While
        the service is stopped, scheduled workflows will not be triggered and the
        gallery is inaccessible. Because of this, it's best to perform a backup during
        a defined maintenance window.

        When scheduling the backup, make sure it doesn't occur when Windows patching is
        scheduled. Also review any scheduled workflows for conflicts with
        the backup time. A running workflow can prevent the Alteryx service from
        stopping and could require force stopping the process. It's a best practice that
        the service is cleanly stopped before a backup.
        
        The duration of the backup process directly correlates with the size of your
        MongoDB. A 13GB database will takes approx 3 min to dump, while a 63GB database
        full of content takes nearly an hour. Once the backup has been completed, the
        Alteryx service is started so the server is accessible.
        
    Multi-Node Deployment Considerations: 
        A more sophisticated approach would be to orchestrate the backup from the Alteryx Controller.
        This would leverage PowerShell Remoting (WinRM) to connect to the remote hosts to stop
        the Alteryx services as part of the backup script. Once the backup completes, the script
        would connect to the remote hosts again to start the Alteryx services.
        
        This requires the account running the backup to be a member of each node's Administrators group.
#>
param (
    [Parameter(Mandatory = $false,
        HelpMessage = "Alteryx API URL")]
    [string]$uri = "https://server.domain.com/webapi/swagger/ui/index",
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

# When all of the remote Alteryx nodes have stopped their AlteryxService the backup can proceed.
$totalScriptTime = Measure-Command {
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

    # Wait for the Alteryx Server API to become available
    [int]$i = 0
    # Get status code from API
    try{
        # Doing in a try/catch to suppress console output
        $request = Invoke-WebRequest -Uri $uri
    }catch{
        # This is the expected output when the Alteryx backup is running
        Write-Host "404 - The API is unavailable" -ForegroundColor Yellow
        Write-Verbsoe "This is expected when the Alteryx backup is running" -Verbose
    }
    while ($request.StatusCode -ne '200') {
        $i++
        Write-Verbose "Attempt $i" -Verbose
        if ($i -ge 40) {
            # If this has been waiting 20 minutes we'll want to try to do something
            Write-Verbose "Waited >40 attempts, it's probably worth checking on the backup" -Verbose
        }
        if ($i -ge 42) {
            # The backup might be taking longer than normal. Terminating this script, manual intervention required.
            Write-Warning "Detected runaway loop"
            break
        }
        # Get status code from API
        try{
            # Doing in a try/catch to suppress console output
            $request = Invoke-WebRequest -Uri $uri
        }catch{
            # This is the expected output when the Alteryx backup is running
            Write-Host "404 - The API is unavailable, pausing for 30 seconds" -ForegroundColor Yellow
            Write-Verbsoe "This is expected when the Alteryx backup is running" -Verbose
            Start-Sleep -Seconds 30
        }
    } # end while $request
    if ($request.StatusCode -eq '200') {
        Write-Host "$uri is online" -ForegroundColor Green 
    }

    # Restarting the Alteryx service
    Set-Service -ServiceName AlteryxService -StartupType Automatic
    $output = "Starting Alteryx Service"; SendOutput -Output $Output
    Start-Service AlteryxService | Out-Null
    $output = "Starting Alteryx Service exit code: $lastexitcode"; SendOutput -Output $Output

    # Define lastWriteTime based on $retention
    $lastWrite = (Get-Date).AddDays(-$retention)

    # Clean up the local backup logs based on lastwrite filter and file name filter
    $logFiles = Get-Childitem $dest -File -Filter "BackupLog-*.csv" | Where-Object { $_.LastWriteTime -lt "$lastWrite" }
    if ($logFiles -ne $null) {
        foreach ($logFile in $logFiles) {
            $Output = "Removing log $logFile"; SendOutput -Output $Output
            Remove-Item -Path $logFile.FullName -Recurse -Force
        }
    }

} # end measure backup script

$Output = 'Ending backup script'; SendOutput -Output $Output
$Output = "Total MongoDB backup time: $totalScriptTime"; SendOutput -Output $Output