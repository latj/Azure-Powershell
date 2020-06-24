Param(
   [string]$resourceGroup = "",
   [string]$VmName = "",
   [string]$SubscriptionName = "", # 
   [string]$TargetVirtualNetworkName = "", # 
   [string]$TargetSubnetName = "", # 
   [string]$TargetSubscriptionName = "" # 

)

# ----------------------------------------------------------
# Script: Move-vm2newsub.ps1
# Version: 0.1
# Author: anders.jansson@microsoft.com
# Date: 2020-06-23
# Keywords: VM, Network, Subscription, Storage
# Comments: VM will dealocated and removed. Then recreated in the new subscription and strated.
# The resource will be placed in a resource group with the same name as at source
# The script will check if the VM is in an AS and create one if not exist in the new rg an add the VM to it.
# The Disk will be copied to the new subscription the source disk will not be deleted
# VMs in Zones can't be moved by this script

# ----------------------------------------------------------

# Login and permissions check
Write-Output ('[{0}] Checking login and permissions.' -f (Get-Date -Format s))
$sub = Select-AzSubscription -SubscriptionName $SubscriptionName -Force
$sub = Set-AzContext -SubscriptionName $SubscriptionName -force

Try {Get-AzResourceGroup -Name $resourceGroup -ErrorAction Stop | Out-Null}
Catch {# Login and set subscription for ARM
    Write-Output ('[{0}] Login to Azure Resource Manager ARM.' -f (Get-Date -Format s))
       Try {$Sub = (Set-AzContext -SubscriptionName $SubscriptionName -force -ErrorAction Stop).Subscription}
       Catch {Connect-AzAccount | Out-Null
              $Sub = (Set-AzContext -Subscription $SubscriptionName -ErrorAction Stop).Subscription}
              Write-Output ('[{0}] Current Sub: {1}({2})' -f (Get-Date -Format s), $Sub.Name, $Sub.Id)
        Try {Get-AzResourceGroup -Name $resourceGroup -ErrorAction Stop | Out-Null}
       Catch {Write-Output ('[{0}] Permission check failed, ensure company id is set correctly.' -f (Get-Date -Format s))
              Return}
}


Write-Output ('[{0}] Starting Post migration script.' -f (Get-Date -Format s))
$newAvailSetName = ""

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
$orginalVM = Get-AzVM `
-ResourceGroupName $resourceGroup `
-Name $vmName -ErrorAction Stop
Write-Output ('[{0}] Exporting vm configuration to file  {1}' -f (Get-Date -Format s), "$home\$($vmName).json" )
# exportsa the VM config to a json file
$orginalVM | ConvertTo-Json -depth 100 | Out-File "$home\$($vmName).json"
Write-Output ('[{0}] Remove VM resource.' -f (Get-Date -Format s))
# Remove the original VM
Remove-AzVM -ResourceGroupName $resourceGroup -Name $vmName
Write-Output ('[{0}] VM is removed.' -f (Get-Date -Format s))


if ($orginalVM.AvailabilitySetReference.Id){
    $res = Get-AzResource -ResourceId $orginalVM.AvailabilitySetReference.Id
    $as = Get-AzAvailabilitySet -ResourceGroupName $res.ResourceGroupName -Name $res.Name
    Write-Output ('[{0}] AvailabilitySet is in use exporting configuration to file  {1}' -f (Get-Date -Format s), "$home\$($res.Name).json" )
    $newAvailSetName = $res.Name
    $as | ConvertTo-Json -depth 100 | Out-File "$home\$(($res.Name)).json"
}

$OsDisk= Get-AzDisk -ResourceGroupName $ResourceGroup -DiskName $orginalVM.StorageProfile.OsDisk.Name
$OldDataDisks = Get-AzDisk -ResourceGroupName $resourceGroup

# jump to target subscription
Write-Output ('[{0}] Switching Subscription.' -f (Get-Date -Format s))
$newsub = Select-AzSubscription -SubscriptionName $TargetSubscriptionName
if ((Get-AzContext).Subscription.Name -ne $TargetSubscriptionName){
    $newsub = Select-AzSubscription -SubscriptionName $TargetSubscriptionName -Force
}


# import the configs from the json files
Write-Output ('[{0}] Importing configurations from file ' -f (Get-Date -Format s))
$orginalVM= Get-Content -Raw -Path "$home\$($vmName).json" | ConvertFrom-Json
$as= Get-Content -Raw -Path "$home\$($res.Name).json" | ConvertFrom-Json

# chiecking if Rg exists
Try {Get-AzResourceGroup -Name $resourceGroup -ErrorAction Stop | Out-Null}
Catch {#
    Write-Output ('[{0}] Resource Group does not exist in targetSubscription it will be created.' -f (Get-Date -Format s))
    New-AzResourceGroup -Name $resourceGroup -Location $orginalVM.Location
}




# Create the basic configuration for the replacement VM
$newVM = New-AzVMConfig -VMName $orginalVM.Name -VMSize $orginalVM.HardwareProfile.VmSize
# Create new availability set if it does not exist
if ($newAvailSetName -ne ""){
    
    $availSet = Get-AzAvailabilitySet `
    -ResourceGroupName $resourceGroup `
    -Name $newAvailSetName `
    -ErrorAction Ignore
    if (-Not $availSet) {
        Write-Output ('[{0}] Create a new AvailabilitySet. [{1}]' -f (Get-Date -Format s), $availSet.Name)
        $availSet = New-AzAvailabilitySet `
        -Location $orginalVM.Location `
        -Name $newAvailSetName `
        -ResourceGroupName $resourceGroup `
        -PlatformFaultDomainCount $as.PlatformFaultDomainCount `
        -PlatformUpdateDomainCount $as.PlatformUpdateDomainCount `
        -Sku $as.Sku
    }
    Write-Output ('[{0}] Adding VM to AvailabilitySet. [{1}]' -f (Get-Date -Format s), $availSet.Name)
    $newVM = New-AzVMConfig -VMName $orginalVM.Name -VMSize $orginalVM.HardwareProfile.VmSize -AvailabilitySetId $availSet.Id
}
#Create a new managed disk in the target subscription and resource group
$OsdiskConfig = New-AzDiskConfig -SourceResourceId $OsDisk.Id -Location $OsDisk.Location -CreateOption Copy
$newOSDisk = New-AzDisk -Disk $OsdiskConfig -DiskName $orginalVM.StorageProfile.OsDisk.Name -ResourceGroupName $ResourceGroup
Write-Output ('[{0}] Copying the OS Disk to target subscription.' -f (Get-Date -Format s))  


$CreateDiskOs = Set-AzVMOSDisk `
    -VM $newVM -CreateOption Attach `
    -ManagedDiskId $newOSDISK.Id `
    -Name $newOSDISK.Name `
    -Windows

# Add Data Disks
foreach ($disk in $orginalVM.StorageProfile.DataDisks) { 
    $DataDisk = $OldDataDisks | Where-Object {$_.name -eq $disk.Name}
    $DatadiskConfig = New-AzDiskConfig -SourceResourceId $DataDisk.Id -Location $DataDisk.Location -CreateOption Copy
    $newDataDisk = New-AzDisk -Disk $DatadiskConfig -DiskName $disk.Name -ResourceGroupName $ResourceGroup
    Write-Output ('[{0}] Copying the DataDisk {1} to target subscription.' -f (Get-Date -Format s),$disk.Name) 
    
    #$newDataDISK = Get-AzDisk -ResourceGroupName $resourceGroup -DiskName $disk.Name
    
    $CreateDiskData = Add-AzVMDataDisk -VM $newVM `
        -Name $newDataDISK.Name `
        -ManagedDiskId $newDataDISK.Id `
        -Caching $disk.Caching `
        -Lun $disk.Lun `
        -DiskSizeInGB $disk.DiskSizeGB `
        -CreateOption Attach
}

# Add NIC(s) and keep the same NIC as primary
$Subnet = Get-AzVirtualNetwork -Name $TargetVirtualNetworkName
$IPconfig = New-AzNetworkInterfaceIpConfig -Name "IPConfig1" -PrivateIpAddressVersion IPv4 -SubnetId ($Subnet.Subnets | Where-Object {$_.Name -eq $TargetSubnetName}).id
$NewNic =New-AzNetworkInterface -Name $vmName -ResourceGroupName $resourceGroup -Location $orginalVM.Location -IpConfiguration $IPconfig
$createNet = Add-AzvmNetworkInterface -VM $newVM -Id $NewNic.id -Primary

# Recreate the VM

    $createVM = New-AzVM `
    -ResourceGroupName $resourceGroup `
    -Location $orginalVM.Location `
    -VM $newVM `
    -DisableBginfoExtension 


Write-Output ('[{0}] Recreation of VM is done.' -f (Get-Date -Format s))

