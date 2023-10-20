<#
.SYNOPSIS
    Updates the server name in Alteryx workflows and saves it as a new file.
.DESCRIPTION
    This script will scan a directory containing Alteryx workflows and update the server name in preparation for a server name change.
.PARAMETER workflowDirectory
    This mandatory string parameter is the path to the directory the Alteryx workflows are stored in.
    Example: "C:\Users\ckite\Desktop\WorkflowRemediation"
.PARAMETER filter
    This option string paramter is the filter that keeps the script from processing other files in the workflow directory.
    Default value: "*.yxmd"
.PARAMETER oldServer
    This manditory string parameter is the name of the old Alteryx server.
    Example: "ALTXAPP01"
.PARAMETER newServer
    This manditory string parameter is the name of the new Alteryx server.
    Example: "ALTXAPP03"
.PARAMETER outputFilePrefix
    This optional string parameter is the prefix that will be added to the name of the updated workflows.
    Default value: "ct-"
.EXAMPLE
    Update-Workflow.ps1 -workflowDirectory "C:\Path\To\Workflows" -oldServer ALTXAPP01 -newServer ALTXAPP03 -Verbose
    This would scan the $workflowDirectory for yxmd files, then replace any instances of the $oldServer with the $newServer.
    Next the script will save the file to the workflow directory with a "ct-" prefix to denote it has been processed.
.NOTES
    Author: Comrad Kite
            Continuus Technologies
    Date:   09/2023
#>



[CmdletBinding()]
param (
    [Parameter(Mandatory=$true)]
    [string]$workflowDirectory,
    [Parameter(Mandatory=$false)]
    [string]$filter = "*.yxmd",
    [Parameter(Mandatory=$true)]
    [string]$oldServer,
    [Parameter(Mandatory=$true)]
    [string]$newServer,
    [Parameter(Mandatory = $false)]
    [string]$outputFilePrefix = "ct-"
)

# Scan directory for workflows
$workflows = Get-ChildItem -Path $workflowDirectory -Filter $filter
Write-Verbose "Found $($workflows.Count) workflow(s)" -Verbose

# Setup tracking variables
$i = 0
$startTimestamp = Get-Date

foreach ($workflow in $workflows){
    $i++
    Write-Verbose "Processing $($workflow.Name) - $i of $($workflows.Count)" -Verbose

    # Because it's faster we'll use .NET methods to read file and update the server name
    $content = [System.IO.File]::ReadAllText($($workflow.FullName)).Replace($oldServer, $newServer)
    
    # Next we'll save the file as a new file with a prefix
    $outputFile = $workflow.Directory.FullName + '\' + $outputFilePrefix + $workflow.name
    [System.IO.File]::WriteAllText($outputFile, $content)
}

# Wrap up and output processed files and duration
$endTimestamp = Get-Date
$timespan = New-TimeSpan -Start $startTimestamp -End $endTimestamp
$runtime = "{0:hh}h:{0:mm}m:{0:ss}s" -f $timespan
Write-Output "Processed $($workflows.Count) workflows in $runtime"