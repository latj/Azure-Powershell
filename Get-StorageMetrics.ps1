param(
    [Parameter(Mandatory = $true)]
    [string]$StorageAccountName,
    
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory = $false)]
    [int]$DaysBack = 1,
    
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "."
)



# Function to validate storage account exists
function Test-StorageAccountExists {
    param(
        [string]$StorageAccountName,
        [string]$ResourceGroupName,
        [string]$SubscriptionId
    )
    
    try {
        if ($SubscriptionId) {
            $storageAccount = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -DefaultProfile (Get-AzContext -ListAvailable | Where-Object {$_.Subscription.Id -eq $SubscriptionId})
        } else {
            $storageAccount = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName
        }
        return $storageAccount
    }
    catch {
        Write-Error "Storage account '$StorageAccountName' not found in resource group '$ResourceGroupName': $($_.Exception.Message)"
        return $null
    }
}

# Validate input parameters
Write-Host "Validating storage account: $StorageAccountName" -ForegroundColor Yellow

$storageAccount = Test-StorageAccountExists -StorageAccountName $StorageAccountName -ResourceGroupName $ResourceGroupName -SubscriptionId $SubscriptionId

if (-not $storageAccount) {
    Write-Error "Cannot proceed without valid storage account"
    exit 1
}

# Build resource ID
if ($SubscriptionId) {
    $resourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Storage/storageAccounts/$StorageAccountName"
} else {
    $context = Get-AzContext
    $resourceId = "/subscriptions/$($context.Subscription.Id)/resourceGroups/$ResourceGroupName/providers/Microsoft.Storage/storageAccounts/$StorageAccountName"
}

Write-Host "Using Resource ID: $resourceId" -ForegroundColor Green
Write-Host "Retrieving metrics for the last $DaysBack day(s)..." -ForegroundColor Yellow

# Get multiple metrics
$transactionMetric = Get-AzMetric -ResourceId $resourceId -MetricNames Transactions -TimeGrain 00:01:00 -StartTime (Get-Date).AddDays(-$DaysBack) -EndTime (Get-Date) -DetailedOutput -AggregationType Average
$egressMetric = Get-AzMetric -ResourceId $resourceId -MetricNames Egress -TimeGrain 00:01:00 -StartTime (Get-Date).AddDays(-$DaysBack) -EndTime (Get-Date) -DetailedOutput -AggregationType Total
$ingressMetric = Get-AzMetric -ResourceId $resourceId -MetricNames Ingress -TimeGrain 00:01:00 -StartTime (Get-Date).AddDays(-$DaysBack) -EndTime (Get-Date) -DetailedOutput -AggregationType Total

# Create hashtables for quick lookup of all metrics by timestamp
$egressLookup = @{}
$ingressLookup = @{}

foreach ($dataPoint in $egressMetric.Data) {
    $egressLookup[$dataPoint.TimeStamp] = $dataPoint.Total
}

foreach ($dataPoint in $ingressMetric.Data) {
    $ingressLookup[$dataPoint.TimeStamp] = $dataPoint.Total
}

# Create enhanced data for CSV export combining all metrics
$exportData = $transactionMetric.Data | Select-Object @{
    Name = 'StorageAccount'
    Expression = { $StorageAccountName }
}, @{
    Name = 'ResourceGroup'
    Expression = { $ResourceGroupName }
}, @{
    Name = 'Date'
    Expression = { $_.TimeStamp.ToString('yyyy-MM-dd') }
}, @{
    Name = 'Time'
    Expression = { $_.TimeStamp.ToString('HH:mm:ss') }
}, @{
    Name = 'Timestamp'
    Expression = { $_.TimeStamp.ToString('yyyy-MM-dd HH:mm:ss') }
}, @{
    Name = 'AvgTransactions'
    Expression = { $_.Average }
}, @{
    Name = 'EgressBytes'
    Expression = { 
        if ($egressLookup.ContainsKey($_.TimeStamp)) { 
            $egressLookup[$_.TimeStamp] 
        } else { 
            0 
        }
    }
}, @{
    Name = 'EgressMB'
    Expression = { 
        if ($egressLookup.ContainsKey($_.TimeStamp)) { 
            [Math]::Round($egressLookup[$_.TimeStamp] / 1MB, 2)
        } else { 
            0 
        }
    }
}, @{
    Name = 'IngressBytes'
    Expression = { 
        if ($ingressLookup.ContainsKey($_.TimeStamp)) { 
            $ingressLookup[$_.TimeStamp] 
        } else { 
            0 
        }
    }
}, @{
    Name = 'IngressMB'
    Expression = { 
        if ($ingressLookup.ContainsKey($_.TimeStamp)) { 
            [Math]::Round($ingressLookup[$_.TimeStamp] / 1MB, 2)
        } else { 
            0 
        }
    }
}

# Create output filename with storage account name
$csvFileName = "$StorageAccountName-Metrics-Export-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
$csvPath = Join-Path $OutputPath $csvFileName

# Export to CSV with custom filename
$exportData | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

Write-Host "`nExport completed successfully!" -ForegroundColor Green
Write-Host "Storage Account: $StorageAccountName" -ForegroundColor Cyan
Write-Host "Resource Group: $ResourceGroupName" -ForegroundColor Cyan
Write-Host "File exported to: $csvPath" -ForegroundColor Green
Write-Host "File contains $($exportData.Count) data points" -ForegroundColor Cyan

# Display summary statistics
Write-Host "`nSummary Statistics for $StorageAccountName:" -ForegroundColor Yellow
Write-Host "Time Range: $(($exportData | Select-Object -First 1).Timestamp) to $(($exportData | Select-Object -Last 1).Timestamp)"
Write-Host "Average Transactions: $([Math]::Round(($exportData | Measure-Object AvgTransactions -Average).Average, 2))"
Write-Host "Total Egress (MB): $([Math]::Round(($exportData | Measure-Object EgressMB -Sum).Sum, 2))"
Write-Host "Total Ingress (MB): $([Math]::Round(($exportData | Measure-Object IngressMB -Sum).Sum, 2))"
Write-Host "Peak Egress (MB): $([Math]::Round(($exportData | Measure-Object EgressMB -Maximum).Maximum, 2))"
Write-Host "Peak Ingress (MB): $([Math]::Round(($exportData | Measure-Object IngressMB -Maximum).Maximum, 2))"