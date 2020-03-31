Param(
   [string]$resourceGroup = "",
   [string]$VmName = "",
   [string]$SubscriptionName = "", # Optional SubscriptionName 
   [string]$newAvailSetName = "" # Optional if needed to att vm to AvaialabilitySet 

)

# ----------------------------------------------------------
# Script: Move-vm2as.ps1
# Version: 0.1
# Author: anders.jansson@microsoft.com
# Date: 2020-03-12
# Keywords: VM, Network, AvaialabilitySet, Storage
# Comments: VM will dealocated and removed. Then recreated in the AvailabilitySet and strated.
# ----------------------------------------------------------

# Login and permissions check
Write-Output ('[{0}] Checking login and permissions.' -f (Get-Date -Format s))
Try {Get-AzResourceGroup -Name $resourceGroup -ErrorAction Stop | Out-Null}
Catch {# Login and set subscription for ARM
    Write-Output ('[{0}] Login to Azure Resource Manager ARM.' -f (Get-Date -Format s))
       Try {$Sub = (Set-AzContext -SubscriptionName $SubscriptionName -ErrorAction Stop).Subscription}
       Catch {Connect-AzAccount | Out-Null
              $Sub = (Set-AzContext -Subscription $SubscriptionName -ErrorAction Stop).Subscription}
              Write-Output ('[{0}] Current Sub: {1}({2})' -f (Get-Date -Format s), $Sub.Name, $Sub.Id)
        Try {Get-AzResourceGroup -Name $resourceGroup -ErrorAction Stop | Out-Null}
       Catch {Write-Output ('[{0}] Permission check failed, ensure company id is set correctly.' -f (Get-Date -Format s))
              Return}
}


Write-Output ('[{0}] Starting Post migration script.' -f (Get-Date -Format s))

if ($SubscriptionName -eq "") {
   Write-Output ('[{0}] Subscription Name not set use current [{1}]' -f (Get-Date -Format s),(Get-AzContext).Subscription.Name)
  
}

if ($VmName -eq "") {
   Write-Output ('[{0}] Missing VM name, You need to add one!' -f (Get-Date -Format s))
   Break  
}
if ([string]::IsNullOrEmpty($(Get-AzContext).Account)){
   $login = Login-AzAccount
   }


# Get the details of the VM to be moved
$originalVM = Get-AzVM `
-ResourceGroupName $resourceGroup `
-Name $vmName -ErrorAction Stop
Write-Output ('[{0}] Exporting vm configuration to file  {1}' -f (Get-Date -Format s), "$home\$($vmName).json" )
# exportsa the VM config to a json file
$originalVM | ConvertTo-Json -depth 100 | Out-File "$home\$($vmName).json"
Write-Output ('[{0}] Remove VM resource.' -f (Get-Date -Format s))
# Remove the original VM
Remove-AzVM -ResourceGroupName $resourceGroup -Name $vmName
Write-Output ('[{0}] VM is removed.' -f (Get-Date -Format s))


# import the VM config from the json file
Write-Output ('[{0}] Importing vm configuration from file {1}' -f (Get-Date -Format s), "$home\$($vmName).json" )
$originalVM= Get-Content -Raw -Path "$home\$($vmName).json" | ConvertFrom-Json


    

# Create the basic configuration for the replacement VM
$newVM = New-AzVMConfig -VMName $originalVM.Name -VMSize $originalVM.HardwareProfile.VmSize
# Create new availability set if it does not exist
if ($newAvailSetName -ne ""){
    
    $availSet = Get-AzAvailabilitySet `
    -ResourceGroupName $resourceGroup `
    -Name $newAvailSetName `
    -ErrorAction Ignore
    if (-Not $availSet) {
        Write-Output ('[{0}] Create a new AvailabilitySet. [{1}]' -f (Get-Date -Format s), $availSet.Name)
        $availSet = New-AzAvailabilitySet `
        -Location $originalVM.Location `
        -Name $newAvailSetName `
        -ResourceGroupName $resourceGroup `
        -PlatformFaultDomainCount 3 `
        -PlatformUpdateDomainCount 5 `
        -Sku Aligned
    }
    Write-Output ('[{0}] Adding VM to AvailabilitySet. [{1}]' -f (Get-Date -Format s), $availSet.Name)
    $newVM = New-AzVMConfig -VMName $originalVM.Name -VMSize $originalVM.HardwareProfile.VmSize -AvailabilitySetId $availSet.Id
}

$newOSDISK = Get-AzDisk -ResourceGroupName $resourceGroup -DiskName $originalVM.StorageProfile.OsDisk.Name

$CreateDiskOs = Set-AzVMOSDisk `
    -VM $newVM -CreateOption Attach `
    -ManagedDiskId $newOSDISK.Id `
    -Name $newOSDISK.Name `
    -Windows

# Add Data Disks
foreach ($disk in $originalVM.StorageProfile.DataDisks) { 
    $newDataDISK = Get-AzDisk -ResourceGroupName $resourceGroup -DiskName $disk.Name
    
    $CreateDiskData = Add-AzVMDataDisk -VM $newVM `
        -Name $newDataDISK.Name `
        -ManagedDiskId $newDataDISK.Id `
        -Caching $disk.Caching `
        -Lun $disk.Lun `
        -DiskSizeInGB $disk.DiskSizeGB `
        -CreateOption Attach
}

# Add NIC(s) and keep the same NIC as primary
$NewNic = Get-AzNetworkInterface -ResourceId $originalVM.NetworkProfile.NetworkInterfaces.id
$createNet = Add-AzvmNetworkInterface -VM $newVM -Id $NewNic.id -Primary

# Recreate the VM
$createVM = New-AzVM `
    -ResourceGroupName $resourceGroup `
    -Location $originalVM.Location `
    -VM $newVM `
    -DisableBginfoExtension


Write-Output ('[{0}] Recreation of VM is done.' -f (Get-Date -Format s))

