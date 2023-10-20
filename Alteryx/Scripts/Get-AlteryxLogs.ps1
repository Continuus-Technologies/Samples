<#
.SYNOPSIS
    Script to collect logs for Alteryx troubleshooting
.DESCRIPTION
    This script will scan all local disk drives for an Alteryx install and copy the logs and runtime settings
    to a directory. Next it will gather information about the SSL certificate, binding, and hostnames in DNS.
    Optionally it will make a copy of the Windows event logs. Finally it will compress and cleanup after itself.
.PARAMETER hours
    This optional integer parameter is used to filter logs to the past X hours.
    This defaults to 24
.PARAMETER outputPath
    This optional string parameter is the path the Alteryx logs will be stored in.
    This defaults to the current user's desktop
.PARAMETER zipName
    This optional string parameter is the prefix of the output directory name.
    This defaults to AlteryxLogs
.PARAMETER eventLogs
    This optional switch parameter is used to collect Windows Event Logs. This requires admin privs.
.EXAMPLE
    Get-AlteryxLogs.ps1 -hours 48 -outputPath "C:\Temp" - zipName "ctAltxLogs"
    Running this would copy 2 days worth of logs to C:\Temp\ctAltxLogs-20230927T1502482925.
.EXAMPLE
    Get-AlteryxLogs.ps1 -eventLogs
    This collects Windows Event Logs. Running this would require running the script as an administrator.
.NOTES
    Author: Comrad Kite
            Continuus Technologies
    Date:   09/2023

    Considerations: A timestamp is appended to the zipName to ensure that if there were 
                    a previous log collection, it won't be accidentally overwritten.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory=$false)]
    [int]$hours = 24,
    [Parameter(Mandatory=$false)]
    [string]$outputPath = $env:USERPROFILE + "\Desktop",
    [Parameter(Mandatory=$false)]
    [string]$zipName = "AlteryxLogs",
    [Parameter(Mandatory=$false)]
    [switch]$eventLogs
)

function  Get-AltxLogs {
    <#
    .SYNOPSIS
        Copies logs from Alteryx folder to destination
    .EXAMPLE
        Get-AltxLogs -path C:\ProgramData\Alteryx
        Checks for logs in time range and saves to a predefined destination
    #>
    
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true,
        HelpMessage = "Path to the Alteryx ProgramData folder")]
        [string]$path
    )
    # Check for Gallery logs
    $gallery = $path + "\Gallery\Logs"
    if (Test-Path -Path $gallery){
        $galleryLogs = Get-ChildItem -Path $gallery -File
        if ($galleryLogs.Count -gt 0){
            New-Item -Path $destination -ItemType Directory -Name Gallery -Force
            $filteredGalleryLogs = $galleryLogs | Where-Object {$_.LastWriteTime -gt ((Get-Date).AddHours(-($hours)))}
            $filteredGalleryLogs | Copy-Item -Destination $destination\Gallery
        }
    }
    # Check for SSO logs
    $sso = $path + "\logs"
    if (Test-Path -Path $sso){
        $ssoLogs = Get-ChildItem -Path $sso -File
        if ($ssoLogs){
            New-Item -Path $destination -ItemType Directory -Name SSO -Force
            $filteredSsoLogs = $ssoLogs | Where-Object {$_.LastWriteTime -gt ((Get-Date).AddHours(-($hours)))}
            $filteredSsoLogs | Copy-Item -Destination $destination\SSO
        }
    }
    # Check for Service logs
    $service = $path + "\Service"
    if (Test-Path -Path $service){
        $serviceLogs = Get-ChildItem -Path $service -File
        if ($serviceLogs){
            New-Item -Path $destination -ItemType Directory -Name Service -Force
            $filteredServiceLogs = $serviceLogs | Where-Object {$_.LastWriteTime -gt ((Get-Date).AddHours(-($hours)))}
            $filteredServiceLogs | Copy-Item -Destination $destination\Service 
        }
        # Check for last startup error file
        $lastStartupError = $serviceLogs | Where-Object {$_.Name -contains "LastStartupError"}
        if ($lastStartupError){
            New-Item -Path $destination -ItemType Directory -Name Service -Force
            $lastStartupError | Copy-Item -Destination $destination\Service 
        }
    }
    # Check for UI Logs
    $ui = $path + "\ErrorLogs"
    if (Test-Path -Path $ui){
        $uiLogs = Get-ChildItem -Path $ui -File
        if ($uiLogs.Count -gt 0){
            New-Item -Path $destination -ItemType Directory -Name ErrorLogs -Force
            $uiLogs = $uiLogs | Where-Object {$_.LastWriteTime -gt ((Get-Date).AddHours(-($hours)))}
            $UiLogs | Copy-Item -Destination $destination\ErrorLogs 
        }
    }
    # Check for Engine Logs
    $engine = $path + "\Engine\Logs"
    # Engine logs are not stored by default.
    if (Test-Path -Path $engine){
        $engineLogs = Get-ChildItem -Path $engine -File
        if ($engineLogs){
            New-Item -Path $destination -ItemType Directory -Name EngineLogs -Force
            $filteredEngineLogs = $engineLogs | Where-Object {$_.LastWriteTime -gt ((Get-Date).AddHours(-($hours)))}
            $filteredEngineLogs | Copy-Item -Destination $destination\EngineLogs
        }
    }
    # Check for RuntimeSettings
    $runtimeSettings = $path + "\RuntimeSettings.xml"
    if (Test-Path -Path $runtimeSettings){
        Copy-Item -Path $runtimeSettings -Destination $destination
    }
}

if ($eventLogs){
    Write-Verbose "The eventLogs switch was specified." -Verbose
    if (([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
        Write-Verbose "Running with administrator privileges." -Verbose
    }else{
        Write-Verbose "Cannot access the Windows Event Logs without administrator privileges." -Verbose
        throw "Not running with administrator privileges. Please run this script as an administrator."
    }
}

# Create output directory
$date = Get-Date -Format FileDateTime
$outputDirectory = $zipName + "-" + $date
try{
    New-Item -Path $outputPath -ItemType Directory -Name $outputDirectory
    Write-Verbose "Created $outputDirectory" -Verbose
    $destination = $outputPath + '\' + $outputDirectory
}catch{
    throw "Unable to create output directory"
}

# Find Alteryx install location and get logs
$volumes = Get-Volume | Where-Object{($_.DriveType -eq 'Fixed') -and ($_.DriveLetter -ne $null)}
foreach ($volume in $volumes){
    $path = ($volume.DriveLetter + ":\ProgramData\Alteryx")
    if (Test-Path -Path $path){
        Write-Verbose "Found Alteryx ProgramData folder on $($volume.DriveLetter)" -Verbose
        Get-AltxLogs -path $path
    }else{
        Write-Verbose "No Alteryx ProgramData folder on $($volume.DriveLetter)"
    }
}

# Get Computer Info (replaces msinfo32) and save as CSV
$computerInfo = Get-ComputerInfo
$computerInfo | Export-CSV -NoTypeInformation -Path $($destination + '\ComputerInfo.csv')
$computerInfo | Select-Object -ExpandProperty OSHotFixes | Export-CSV -NoTypeInformation -Path $($destination + '\OSHotFixes.csv')

# Check if cert installed and bound
$netshOutput = (netsh http show sslcert)
$applicationID = [regex]::Match($netshOutput, 'Application ID\s+: \{([0-9a-fA-F-]+)\}').Groups[1].Value
if ($null -eq $applicationID){
    Write-Warning "There is no certificate bound to Alteryx"
}elseif ($applicationID -eq 'eea9431a-a3d4-4c9b-9f9a-b83916c11c67'){
    Write-Verbose "Alteryx has a cert bound to it" -Verbose
    $certificateHash = [regex]::Match($netshOutput, 'Certificate Hash\s+: ([0-9a-fA-F]+)').Groups[1].Value
}else{
    throw "The cert is not bound to Alteryx application id. You might want to take a look at that manually."
}

# Inspect Alteryx certificate
$certs = Get-ChildItem -Path Cert:\LocalMachine\My
$alteryxCert = $certs | Where-Object {($_.NotAfter -gt (Get-Date)) -and ($_.Thumbprint -eq $certificateHash)}
if ($alteryxCert.HasPrivateKey){
    Write-Verbose "The certificate has a private key" -Verbose
}else{
    Write-Warning "The certificate does not have a private key!"
}
$props = @(
    'FriendlyName',
    'HasPrivateKey',
    'Issuer',
    'NotAfter',
    'NotBefore',
    'Subject',
    'Thumbprint'
)
# Export certificate details to CSV
$alteryxCert | Select-Object $props | Export-Csv -Path $destination\alteryxCert.csv -NoTypeInformation -Force

# Get DNS names on certificate
$dnsNames = $alteryxCert.DnsNameList.Unicode | Where-Object { $_ -match '^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$' }
# Query DNS in parallel
$jobs = $dnsNames | ForEach-Object {
    $hostname = $_
    Start-Job -ScriptBlock {
        param(
            [string]$hostname,
            [string]$destination
        )
        try{
            Resolve-DnsName -Name $hostname -DnsOnly -Type A -ErrorAction Stop
        }catch{
            New-Item -Path $using:destination\unresolvable-hostname.txt -ItemType File -Value $hostname
            Write-Verbose "Certificate has unresolvable hostname: $($hostname)" -Verbose
        }
    } -ArgumentList $hostname, $destination
}
$jobs | Wait-Job
# Collect results and and save as CSV
$jobResults = $jobs | Receive-Job
$jobs | Remove-Job
$jobResults | Select-Object Name, Type, IPAddress, NameHost | Export-Csv -Path $destination\dns-records.csv -Force -NoTypeInformation

if ($eventLogs){
    # This needs to be run as an administrator
    # Collect Windows logs
    # The security log can be MASSIVE depending on the audit policy configuration
    $logNames = @('Application','System'<#, 'Security'#>)
    $endTime = Get-Date
    $startTime = $endTime.AddHours(-($hours))
    Write-Verbose "Collecting Windows Event Logs" -Verbose
    foreach ($logName in $logNames){
        # Get events within the specified time range
        $events = Get-WinEvent -FilterHashtable @{
            LogName = $logName;
            StartTime = $startTime;
            EndTime = $endTime
        }
        $logFileName = $logName + "EventLog.csv"
        # Export events to a CSV file
        $events | Export-Csv -Path $destination\$logFileName -NoTypeInformation
    }
}

# Create a zip file for sending to Alteryx
Write-Verbose "Compressing logs" -Verbose
foreach ($item in $destination) {
    $archive = $destination + '.zip'
    if (Test-Path $archive) { 
        Remove-Item $archive 
    }
    # Compression options: [Fastest / NoCompression / Optimal / SmallestSize]
    $compressionLevel = [System.IO.Compression.CompressionLevel]::Fastest
    # Calling the .NET API directly
    Add-Type -Assembly "System.IO.Compression.Filesystem"
    if ((Get-Item -Path $item) -is [System.IO.DirectoryInfo]) {
        # This is directory, not a file
        [System.IO.Compression.ZipFile]::CreateFromDirectory($item, $archive, $compressionLevel, $true)
    }
    else {
        # This is a file, not a directory
        $zip = [System.IO.Compression.ZipFile]::Open($archive, 'update')
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $item, (Split-Path $item -Leaf), $compressionLevel)
        # This closes the file, if we didn't do this it would remain open
        $zip.Dispose()
    }
}

# Check if the zip file exists and cleanup
if (Test-Path ($destination + '.zip')) {
    try {
        # Attempt to open the zip file
        $zipFile = [System.IO.Compression.ZipFile]::OpenRead($destination + '.zip')
        Write-Verbose "The zip file is valid." -Verbose
        # This closes the file, if we didn't do this it would remain open
        $zipFile.Dispose()
        # Remove original folder
        Remove-Item -Path $destination -Recurse
    }
    catch {
        throw "The zip file is invalid or corrupted."
    }
}else {
    throw "The zip file does not exist."
}
