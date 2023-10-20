#requires -RunAsAdministrator
<#
.SYNOPSIS
    Alteryx Server MongoDB Backup PowerShell Script
.DESCRIPTION
    This script will backup the Alteryx Server MongoDB locally,
    then will create a compressed copy of the backup on a remote system. 
.PARAMETER dest
    The path the local backup will be created in.
    Defaults to [C:\Temp\MongoDB-Backup]
.PARAMETER destRetention
    The number of days the local backup will be stored. This script will prune older backups/logs based on this.
    By default, this is set to 1
.PARAMETER archive
    The path that the remote, compressed, backup will be stored.
    Defaults to [\\NAS.DOMAIN.COM\Backups\Alteryx-Node1\MongoDB-Backups]
.PARAMETER archiveRetention
    The number of days the remote archives will be stored. This script will prune older backups based on this.
    By default, this is set to 4
.PARAMETER source
    This array contains the directories to include in the backup.
    By default, this will be empty and the script will add to the array at runtime
.PARAMETER dbPath
    The path to the MongoDB. This can be found in Alteryx's persistence settings.
    Defaulst to [C:\ProgramData\Alteryx\Service\Persistence\MongoDB]
.PARAMETER binPath
    The path to the Alteryx service binary/executable.
    Defaults to [C:\Program Files\Alteryx\bin]
.PARAMETER fileList
    This array contains additional files to include in the backup.
    By default, this will contain the path to Alteryx's RuntimeSettings.xml
.EXAMPLE
    Backup-AlteryxServer [[-dest] E:\Temp\MongoDB_Backup] [[-archive] \\FILER.DOMAIN.COM\Share\Alteryx\MongoDB-Backups]
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

        The backup is then copied to a compressed file on a remote SMB file share. On
        average the overall process should take about 30 minutes but its all down to
        the content of the DB and the speed of the network.
        
    Multi-Node Deployment Considerations: 
        In a multi-node environment, where the role of an Alteryx server are on different hosts,
        the Alteryx service will need to be stopped on the remote hosts before the MongoDB can
        be stopped for a backup.

        For Gallery and Worker nodes, this could be accomplished by a Scheduled Task on
        the remote machines that stops the Alteryx service prior to the backup window and a
        second task that starts the service at the end of the backup window.
            - Stop-AlteryxServer.ps1
            - Start-AlteryxServer.ps1

        For Worker nodes, the task watches (queries) the Alteryx server API, which is served by
        the Gallery, and waits to start the service until it responds with a HTTP 200 OK message.
            - Watch-AlteryxBackup.ps1

        A more sophisticated approach would be to leverage WinRM and connect to the remote
        hosts to stop the Alteryx service as part of the backup script, starting the service
        once the backup has completed.

    Attribution: This script is loosely based on an example found on the Alteryx Community.
    https://community.alteryx.com/t5/Alteryx-Server-Knowledge-Base/Alteryx-Server-Backup-and-Recovery-Part-2-Procedures/tac-p/357058/highlight/true#M305
#>
param (
    [Parameter(Mandatory = $false,
        HelpMessage = "The path the local backup will be created in.")]
    [string]$dest = "C:\Temp\MongoDB-Backup",
    [Parameter(Mandatory = $false,
        HelpMessage = "The number of days to retain a backup.")]
    [string]$destRetention = '1',
    [Parameter(Mandatory = $false,
        HelpMessage = "The path that the remote, compressed, backup will be stored.")]
    [string]$archive = "\\NAS.DOMAIN.COM\Backups\Alteryx-Node1\MongoDB-Backups",
    [Parameter(Mandatory = $false,
        HelpMessage = "The number of days to retain a backup.")]
    [string]$archiveRetention = '4',
    [Parameter(Mandatory = $false,
        HelpMessage = "Additional directories to include in the backup.")]
    [System.Collections.ArrayList]$source = @{},
    [Parameter(Mandatory = $false,
        HelpMessage = "The path to the MongoDB.")]
    [string]$dbPath = "C:\ProgramData\Alteryx\Service\Persistence\MongoDB",
    [Parameter(Mandatory = $false,
        HelpMessage = "The path to the Alteryx binary")]
    [string]$binPath = "C:\Program Files\Alteryx\bin",
    [Parameter(Mandatory = $false,
        HelpMessage = "Additional files to include in the backup.")]
    [System.Collections.ArrayList]$fileList = @(
        "C:\ProgramData\Alteryx\RuntimeSettings.xml"
    )
)

if (!(Test-Path $dest)) {
    try {
        New-Item -ItemType directory -Path $dest -ErrorAction Stop
        Write-Output "The local backup path, $dest, was created automatically"
    }
    catch {
        Write-Output "The local backup path, $dest, is inaccessible. Check path."
    }
}

if (!(Test-Path $archive)) {
    try {
        New-Item -ItemType directory -Path $archive -ErrorAction Stop
        Write-Output "The archive path, $archive, was missing and created automatically"
    }
    catch {
        Write-Output "The archive path, $archive, is inaccessible. Check path."
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

$totalScriptTime = Measure-Command {
    $Output = 'Beginning backup script'
    SendOutput -Output $Output

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

    Start-Sleep 2

    # Check if the lock file is in use
    $lockFile = $dbPath + "\Mongod.lock"
    #$lockFile = "C:\ProgramData\Alteryx\Service\Persistence\MongoDB\Mongod.lock"
    Remove-Item "$lockfile" -Force -ErrorAction SilentlyContinue
    if (!(Test-Path $lockfile)) {
        New-Item $lockfile
    }
    else {
        $output = "Check the lockfile, $($lockFile)"; SendOutput -Output $Output
        break
    }

    $Output = "Starting MongoDB backup"
    SendOutput -Output $Output

    # Creating the emondodump backup, calling Alteryx binary directly using &
    $dumpname = "MongodbDump_$(Get-Date -f yyyy-MM-dd-HH-mm)"
    $dump = & "$binPath\AlteryxService.exe" emongodump=$dest\$dumpname -Wait
    $result = $dump.ExitCode
    if ($result -eq "False") {
        $output = "MongoDB backup failed during dump"
        SendOutput -Output $Output
        break
    }
    else {
        $output = "MongoDB backup completed"
        SendOutput -Output $Output
        $Source.Add("$dest\$dumpname")
    }

    # Restarting the Alteryx service
    Set-Service -ServiceName AlteryxService -StartupType Automatic
    $output = "Starting Alteryx Service"
    SendOutput -Output $Output
    Start-Service AlteryxService | Out-Null
    $output = "Starting Alteryx Service exit code: $lastexitcode"
    SendOutput -Output $Output

    # Add additional files to $dest
    foreach ($file in $filelist) {
        $sourceFile = $file
        Get-ChildItem $sourceFile | Copy-Item -Recurse -Destination $dest\$dumpname
        $destFile = $sourceFile.Split('\') | Select-Object -Last 1
        # Make sure the copy matches the source
        if ((Get-FileHash $sourceFile).Hash -ne (Get-FileHash $dest\$dumpname\$destFile).Hash) {
            $Output = "Copy to remote archive failed. $dest\$destFile - $file hashes don't match"
            SendOutput -Output $Output
        }
        else {
            $Output = "Copy to remote archive successful. $dest\$destFile - $file hashes match"
            SendOutput -Output $Output
        }
    }

    # Create a compressed file on the $archive and copy the backup from $dest for long term storage
    Write-Host "Beginning archival process" -ForegroundColor Cyan

    $compressionDuration = Measure-Command {
        
        foreach ($item in $Source) {
            # If this is running as a Scheduled Task, validate that the account running the task has permissions
            # setup to allow access the $archive location.
            $destination = "$archive\AlteryxBackup-$logdate.zip"
            $archiveDuration = Measure-Command {
                if (Test-Path $destination) { 
                    Remove-Item $destination 
                }
                # Compression options: [Fastest / NoCompression / Optimal / SmallestSize]
                $compressionLevel = [System.IO.Compression.CompressionLevel]::Fastest
                # Calling the .NET API directly
                Add-Type -Assembly "System.IO.Compression.Filesystem"
                # Figure out if $item is a directory or a file
                if ((Get-Item -Path $item) -is [System.IO.DirectoryInfo]) {
                    # This is directory, not a file
                    [System.IO.Compression.ZipFile]::CreateFromDirectory($item, $destination, $compressionLevel, $true)
                    # Below is another way to archive the contents of the directory
                    # Get-ChildItem $FilesDirectory | ForEach-Object {[System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $_.FullName, (Split-Path $_.FullName -Leaf), $compressionLevel)}
                }
                else {
                    # This is a file, not a directory
                    $zip = [System.IO.Compression.ZipFile]::Open($destination, 'update')
                    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $item, (Split-Path $item -Leaf), $compressionLevel)
                    # This closes the file, if we didn't do this it would remain open
                    $zip.Dispose()
                }
            } # end measure compression
            $archiveSeconds = $archiveDuration.Seconds
            $Output = "$item took $archiveSeconds seconds to compress."
            SendOutput -Output $Output
        }
    } # end measure archival

    $compressionSeconds = $compressionDuration.Seconds
    $Output = "Total compression time: $compressionSeconds"
    SendOutput -Output $Output

    $Output = "Backup archival to $archive complete"
    SendOutput -Output $Output

    # Define lastWriteTime based on $retention
    $lastWrite = (Get-Date).AddDays(-$destRetention)

    # Clean up the local backups based on lastwrite filter and folder filter
    $backups = Get-ChildItem $dest -Directory -Filter "MongodbDump*" | Where-Object { $_.LastWriteTime -lt "$lastWrite" }
    if ($backups -ne $null) {
        foreach ($backup in $backups) {
            $Output = "Removing backup $backup"; SendOutput -Output $Output
            Remove-Item -Path $backup.FullName -Recurse -Force
        }
    }
    # Clean up the local backup logs based on lastwrite filter and file name filter
    $logFiles = Get-Childitem $dest -File -Filter "BackupLog-*.csv" | Where-Object { $_.LastWriteTime -lt "$lastWrite" }
    if ($logFiles -ne $null) {
        foreach ($logFile in $logFiles) {
            $Output = "Removing log $logFile"; SendOutput -Output $Output
            Remove-Item -Path $logFile.FullName -Recurse -Force
        }
    }

    # Define lastWriteTime based on $retention
    $lastWrite = (Get-Date).AddDays(-$archiveRetention)

    # Clean up the archived remote backups based on lastwrite filter and file name
    $archiveFiles = Get-Childitem "$archive\Backup*.zip" -Recurse | Where-Object { $_.LastWriteTime -lt "$lastWrite" }
    if ($archiveFiles -ne $null) {
        foreach ($zipArchive in $archiveFiles) {
            $Output = "Removing archive $zipArchive"; SendOutput -Output $Output
            Remove-Item -Path $zipArchive.FullName -Recurse -Force
        }
    }

} # end measure backup script

$Output = 'Ending backup script'; SendOutput -Output $Output
$Output = "Total MongoDB backup time: $totalScriptTime"; SendOutput -Output $Output