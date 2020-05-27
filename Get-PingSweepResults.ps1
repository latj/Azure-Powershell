<#
    .SYNOPSIS
        Use Log Analytics query to test-Netconnections from a server
 
    .DESCRIPTION
        This scripts runs a Log Analytics query to collect the outbound Service Map data from a server. And then test net connection to all destination IP.
        And save the result i a CSV file 
        The Log analytics query is dependant two saved function that must exist in the workspace, they are named fexcludeProcessNames and fexcludeRemoteIPs
        Sample of functions
        
        fexcludeProcessNames

        let excludeProcessNames = datatable (ProcessName: string) [      
        // Windows exclusions
        @"MonitoringHost",     
        @"HealthService",
        @"masvc",
        @"McScript_InUse",
        @"CcmExec",
        @"BBWin",
        @"lsass",
        @"mcdatrep",
        @"macmnsvc",
        @"ccmeval",
        @"xferwan",
        @"mgntagnt",
        // Linux exclusions
        @"trapsd"
        ]; excludeProcessNames

        fexcludeRemoteIPs

        let excludeRemoteIPs = datatable (DestinationIp: string) [ "127.0.0.1",
        // IPaddresses
        "192.168.1.1",
        "255.255.255.0" ]; excludeRemoteIPs;



 
    .PARAMETER FirstParameter
        Description of each of the parameters.
        Note:
        To make it easier to keep the comments synchronized with changes to the parameters,
        the preferred location for parameter documentation comments is not here,
        but within the param block, directly above each parameter.
 
    .PARAMETER SecondParameter
        Description of each of the parameters.
 
    .INPUTS
        subscriptionid
        resourcegroupname
        workspacename
        computername
 
    .OUTPUTS
        the result is exported to a csv file namned as the computername in same folder.
 
    .EXAMPLE
        Example of how to run the script.
        .\Get-PingSweepResults.ps1 -subscriptionid "xxxxxxxxxxxxxx" -resourcegroupname "rgname" -workspacename "xxxxxx" -computername "servername"
        

 
    .LINK
        Links to further documentation.
 
    .NOTES
        Detail on what the script does, if this is needed.
 
#>



[CmdletBinding()]
Param (
[Parameter(Mandatory=$true)] [string]$subscriptionid,
[Parameter(Mandatory=$true)] [string]$resourcegroupname,
[Parameter(Mandatory=$true)] [string]$workspacename,
[Parameter(Mandatory=$true)] [string]$computername = ""
)
if (Get-Module -ListAvailable -Name Az) {
    Write-Host "Az Module is installed"
} 
else {
    Write-Host "Need to install Az Module. install-module -Name Az "
    exit
}
# Login to Azure if needed
if ([string]::IsNullOrEmpty($(Get-AzContext).Account)){
    $login = Login-AzAccount
}
# change focus to current Subscription
if ((Get-AzContext).Subscription.id -ne $subscriptionid){
    $context = Set-AzContext -Subscription $subscriptionid
}


# Query to use
$query = @"
let ComputerName = "$computername";
VMConnection
| where TimeGenerated > ago(7d)
| where Direction == "outbound"
| where Computer == ComputerName
| join kind= leftanti (
   fexcludeRemoteIPs 
   | project DestinationIp
) on DestinationIp
| join kind= leftanti (
   fexcludeProcessNames 
   | project ProcessName 
) on ProcessName  
| distinct DestinationIp, DestinationPort, SourceIp, ProcessName
"@ 
# dispaly the query
Write-Host "The following query was used to query Log Analytics"
$query
# collect info about Log Analytics Workspace and preform the query
$workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $resourcegroupname -Name $workspacename
$res = [System.Linq.Enumerable]::ToArray((Invoke-AzOperationalInsightsQuery -WorkspaceId $workspace.CustomerId -Query $query).Results)
# Start Job from query result
$jobs = @()
foreach ($row in $res)
{
    while (@(Get-Job -State Running).Count -ge 10)
    {
        Start-Sleep -Seconds 5
    }
    $scriptBlock = {
        $test = Test-NetConnection -ComputerName $using:row.DestinationIp -Port $using:row.DestinationPort
        [PSCustomObject]@{
            SourceIp = $using:row.SourceIp
            RemoteAddress = $test.RemoteAddress
            RemotePort = $test.RemotePort
           PingSucceeded = $test.PingSucceeded
            TcpTestSucceeded = $test.TcpTestSucceeded
           Latency = $test.PingReplyDetails.RoundtripTime
           SourceProcessName = $using:row.ProcessName
        }
    }
    $jobs += Start-Job -ScriptBlock $scriptBlock
    Write-Output ("{0}/{1} jobs started." -f $jobs.count, $res.count)
}
# Export info to a CSV file
$data = $jobs | Wait-Job | Receive-Job | Select-Object SourceIp, RemoteAddress, RemotePort,PingSucceeded, TcpTestSucceeded, Latency, SourceProcessName
$data | Export-Csv -Path .\$computerName.csv -Encoding UTF8 -Delimiter ";" -NoTypeInformation


