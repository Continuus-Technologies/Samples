# Alteryx

### Description
This directory contains scripts created to aid in the administration of an Alteryx server running on Windows Server.

## Backup Scripts
### Backup-AlteryxServer.ps1

The `Backup-AlteryxServer` PowerShell script will create a backup of the Alteryx database and configuration. Having seen only a handful of servers, and equally as many troubled upgrades, it's always good to have a solid backup *before* you need it.

To help clients that haven't developed their own backups, this script can quickly be setup as a Scheduled Task in Windows.

When executed, the script will stop the Alteryx service, export the MongoDB, and start the Alteryx service so that it is accessible to users while it completes the archival of the backup. Only members of the server's local `Administrators` group can start/stop services, so we'll need our service account added to that.

To create the archive of the backup, the script uses .NET APIs to a compressed copy of the backup on a remote file share. By leveraging the APIs, we avoid having to install a 3rd party application like 7zip on a client's server.
Finally, the script will perform some housekeeping, removing backups that are older than the retention threshold.

### Create-AlteryxBackupTask.ps1

The `Create-AlteryxBackupTask` PowerShell script is a companion to the `Backup-AlteryxServer` and will create a Scheduled Task. This Scheduled Task will be configured with a `Run as` service account that will need to be a member of the `Administrators` group.

When executed, the script will prompt the user for the credentials for the service account. It does this to prevent accidentally persisting the password to the history of commands run from the shell. It will then grant the service account permission to log on as a batch job.

By default, this script will configure the scheduled task to run on weeknights at 11pm. This allows for patching to occur on the weekends.

### Watch-AlteryxBackupTask.ps1

When executed, the `Watch-AlteryxBackup` PowerShell script will stop the Alteryx service on a worker node. It will then watch the Alteryx API that is served by the Gallery to respond with a HTTP 200 OK status message and start the Alteryx service so that it is accessible to users while it completes the archival of the backup.

### Stop-AlteryxService.ps1

When executed, the `Stop-AlteryxService` PowerShell script will stop the Alteryx service on the node. This is intended to be triggered by a Scheduled Task at the beginning of the maintenance window.

### Start-AlteryxService.ps1

When executed, the `Start-AlteryxService` PowerShell script will stop the Alteryx service on the node. This is intended to be triggered by a Scheduled Task at the end of the maintenance window.

## Troubleshooting Scripts
### Get-AlteryxLogs.ps1

When executed, the `Get-AlteryxLogs` PowerShell script will scan the server's local disks for Alteryx installations. It will then copy the 2 days, configurable, of logs to a folder on the user's desktop.

Next it will check to see if Alteryx has a SSL certificate bound to it. If so, it will check the valid names on the certificate and attempt to query them in DNS. It will collect additional computer information, including installed Windows hotfixes. This is all saved to the desktop folder. If it's running as an administrator, it can collect Windows Application and System event logs.

Once complete, it will compress the folder on the desktop, creating a zip file, and then it will remove the uncompressed folder.

## Misc Scripts
### Update-Workflows.ps1

When executed, the `Update-Workflows` PowerShell script will find and replace the a server name in all of the Alteryx workflows in the provided directory. This is useful when migrating to a server that doesn't share the same name. This can also be used to update the server name in other paths, like file shares, in the workflows as well.