#Requires -Module Ansible.ModuleUtils.Legacy

# Result object 
$module = New-Object psobject @{
    result  = ""
    changed = $false
    msg     = ""
    status  = ""
    failed  = $false
    data    = ""
}


$ErrorActionPreference = "Stop"

# --- Read and parse incoming parameters ---
$params           = Parse-Args $args -supports_check_mode $true
$esxi_action      = Get-AnsibleParam -obj $params -name "esxi_action" -type "str" -failifempty $false
$esxi_host        = Get-AnsibleParam -obj $params -name "esxi_host" -type "str" -failifempty $false
$esxi_user        = Get-AnsibleParam -obj $params -name "esxi_user" -type "str" -failifempty $false
$esxi_password    = Get-AnsibleParam -obj $params -name "esxi_password" -type "str" -secret $true -failifempty $false
$esxi_cert_path   = Get-AnsibleParam -obj $params -name "esxi_cert_path" -type "str" -failifempty $false
$vcenter_server   = Get-AnsibleParam -obj $params -name "vcenter_server" -type "str" -failifempty $false
$vcenter_user     = Get-AnsibleParam -obj $params -name "vcenter_user" -type "str" -failifempty $false
$vcenter_password = Get-AnsibleParam -obj $params -name "vcenter_password" -type "str" -secret $true -failifempty $false
$esxi_location    = Get-AnsibleParam -obj $params -name "esxi_location" -type "str" -failifempty $false
$target_datacenter = Get-AnsibleParam -obj $params -name "target_datacenter" -type "str" -failifempty $false
$target_cluster = Get-AnsibleParam -obj $params -name "target_cluster" -type "str" -failifempty $false


function update-error([string] $description) {
    $module.status = 'Error'
    $module.msg = "Error - $description. $($_.Exception.Message)"
    $module.failed = $true
}

try {

    # --- Set vCenter in modo custom ---
    if ($esxi_action -eq "custom_mode") {
        try {
            Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
            $vcConn = Connect-VIServer -Server $vcenter_server -User $vcenter_user -Password $vcenter_password -ErrorAction Stop
            $module.msg += "Connected to vCenter. "
            $certModeSetting = Get-AdvancedSetting -Name "vpxd.certmgmt.mode" -Entity $vcConn -Server $vcConn
            Set-AdvancedSetting -AdvancedSetting $certModeSetting -Value "custom" -Confirm:$false
            $module.msg += "Set vpxd.certmgmt.mode to 'custom'. "
            Disconnect-VIServer -Server $vcConn -Confirm:$false
            $module.changed = $true
            $module.status = "Success"
        } catch {
            update-error "Failed to set vCenter to custom mode"
            Exit-Json $module
        }
    }

    # --- ESX in maintenance mode ---
    elseif ($esxi_action -eq "maintenance") {
        try {
            Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
            $vcConn = Connect-VIServer -Server $vcenter_server -User $vcenter_user -Password $vcenter_password -ErrorAction Stop
            $esxi = Get-VMHost -Name $esxi_host
            
            if (-not $esxi){ throw "Host $esxi_host not found in vCenter"
            }

            #turning off vms 
            $stoppedvms = @()
            $vmstopoweroff = Get-VM -Server $vcConn | Where-Object { $_.VMHost -eq $esxi -and $_.PowerState -eq "PoweredOn" }

            if ($vmstopoweroff){ 
                foreach ($vm in $vmstopoweroff) { 
                    Write-Host "Turning off VM: $($vm.Name)" 
                    Stop-VM -VM $vm -Confirm:$false
                    $stoppedvms += $vm.Name
                }

                do {
                    $poweredOnVMs = Get-VM -Server $vcConn | Where-Object { $_.VMHost -eq $esxi -and $_.PowerState -eq "PoweredOn" }
                    if ($poweredOnVMs.Count -gt 0) {
                        Write-Host "Waiting for VMs to be powered off..."
                        Start-Sleep -Seconds 5
                    }
                } while ($poweredOnVMs.Count -gt 0)
            }
            else{
                Write-Host "No VMs found in host"
            }


            Write-Host "Starting to configure maintenance mode..."
            Set-VMHost -VMHost $esxi -State Maintenance


            $module.msg += "ESXi host $esxi_host set to maintenance mode. "

            $module.data = @{
                PoweredOffVMs = $stoppedvms
            }
            Write-Host "The following VMs were turned off: $($stoppedvms -join ', ')"
            
            $module.changed = $true
            $module.status = "Success"
        }
        catch {
            update-error "Failed to put ESXi host into maintenance mode"
            Exit-Json $module
        }
    }

    elseif ($esxi_action -eq "remove") {
        try {
            $vcConn = Connect-VIServer -Server $vcenter_server -User $vcenter_user -Password $vcenter_password -ErrorAction Stop
            $vmhost = Get-VMHost -Name $esxi_host -Server $vcConn
            
            if ($vmhost.State -ne "Maintenance") {
                throw "Host '$($vmhost.Name)' is not in maintenance mode"
            }

            if (-not $vmhost) {throw "No host found with that name"}

            
            $datacenter = ($vmhost | Get-Datacenter -Server $vcConn).Name
            $cluster = ($vmhost | Get-Cluster -Server $vcConn -ErrorAction SilentlyContinue).Name

            #Después (limpia control chars y trim)
            $datacenter = (($vmhost | Get-Datacenter -Server $vcConn).Name | ForEach-Object { $_.ToString() })
            $cluster    = (($vmhost | Get-Cluster    -Server $vcConn -ErrorAction SilentlyContinue).Name | ForEach-Object { $_.ToString() })
            
            $datacenter = $datacenter -replace '[\x00-\x1F]',''
            $cluster    = $cluster    -replace '[\x00-\x1F]',''
            
            $datacenter = $datacenter.Trim()
            $cluster    = $cluster.Trim()

            if (-not $module.data) { $module.data = @{} }

            $esx_location = @{
                Datacenter = $datacenter
                Cluster = $cluster
            }
            if (-not $module.data) { $module.data = @{} }
            $module.data.HostLocation = $esx_location

            Write-Host "Host location: "
            Write-Host "Datacenter: $datacenter"
            Write-Host "Cluster: $cluster"

            $vdSwitches = Get-VDSwitch -VMHost $vmhost -Server $vcConn -ErrorAction SilentlyContinue

            if ($vdSwitches) {
                Write-Host "$esxi_host is connected to the following VDS: $($vdSwitches.Name -join ',')"
                if (-not $module.data) { $module.data = @{} }
                $module.data.RemovedVDSwitches = $vdSwitches.Name

                foreach ($vds in $vdSwitches) {
                    #find VMkernel adapters used in VDS
                    $vmkToRemove = Get-VMHostNetworkAdapter -VMHost $vmhost -DistributedSwitch $vds -VMKernel 

                    if ($vmkToRemove) {
                        #To migrate VMkernel adapters to standard switch
                        Write-Host "Removing VMkernel adaptors..."
                        Remove-VMHostNetworkAdapter -Nic $vmkToRemove -Confirm:$false         
                    }
                        Write-Host "Disconnecting host from VDS: $($vds.Name)"
                        Remove-VDSwitchVMHost -VDSwitch $vds -VMHost $vmhost -Confirm:$false
                }
                $module.msg += "Host has been disconnected from all VDS"
            } else {
                Write-Host "$esxi_host is not connected to a VDS"
            }
            #verifying if esx connectivity 
            
            Write-Host "Removing $esxi_host from vCenter"
            Remove-VMHost $vmhost -Confirm:$false
            Write-Host "ESXi has been removed successfully"

            $module.msg += "ESXi $esxi_host has been removed from vCenter."
            $module.changed = $true
            $module.status = "Success"
        }
        catch {
            update-error "Failed to remove $esxi_host from vCenter"
            Exit-Json $module
        }
    }

    # --- Replace ESXi certificate ---
    elseif ($esxi_action -eq "replace_cert") {
        try {
            # 1. Conectar directamente al host ESXi
            Write-Host "Connecting directly to ESXi host: $esxi_host"


            $esxConnection = Connect-VIServer -Server $esxi_host -User $esxi_user -Password $esxi_password -ErrorAction Stop -Confirm:$false

            # 2. Leer el nuevo certificado desde el archivo .pem
            Write-Host "Reading certificate from: $esxi_cert_path"
            $esxCertificatePem = Get-Content -Raw -Path $esxi_cert_path
            
            # 3. Obtener el objeto del host para el comando
            $targetEsxHost = Get-VMHost -Name $esxi_host -Server $esxConnection
            
            # 4. Establecer el nuevo certificado de máquina en el host
            Write-Host "Setting new machine certificate on $esxi_host..."
            Set-VIMachineCertificate -PemCertificate $esxCertificatePem -VMHost $targetEsxHost -Confirm:$false | Out-Null
            
            # 5. Reiniciar el host para que el cambio de certificado tenga efecto (mandatorio)
            Write-Host "Restarting host $esxi_host to apply certificate changes..."
            Restart-VMHost -VMHost $targetEsxHost -Confirm:$false 
            
            $module.msg = "New certificate has been set on $esxi_host. A host reboot has been initiated."
            $module.changed = $true
            $module.status = "Success"
                        
        } catch {
            update-error "Failed to replace certificate on ESXi host $esxi_host"
            # Intentar desconectar si la conexión aún existe
            if (Get-VIServer -Server $esxi_host -ErrorAction SilentlyContinue) {
                Disconnect-VIServer -Server $esxi_host -Confirm:$false
            }
            Exit-Json $module
        }
    }

    elseif ($esxi_action -eq "re-add") {
        try {
            #log de entrada 
            $module.msg += "[re-add] Inputs -> Host: $esxi_host, DC: $target_datacenter, cluster: $target_cluster."
            if (-not $target_datacenter) {throw "No location found for ESXi host in module data"}
            $target_datacenter = ($target_datacenter | ForEach-Object { $_.ToString() })
            $target_cluster    = ($target_cluster    | ForEach-Object { $_.ToString() })
            $target_datacenter = $target_datacenter -replace '[\x00-\x1F]',''
            $target_cluster    = $target_cluster    -replace '[\x00-\x1F]',''
            $target_datacenter = $target_datacenter.Trim()
            $target_cluster    = $target_cluster.Trim()


            $vcConn = Connect-VIServer -Server $vcenter_server -User $vcenter_user -Password $vcenter_password -ErrorAction Stop
            $module.msg += "[re-add] Connected to vCenter $vcenter_server `n"

            $existing = Get-VMHost -Name $esxi_host -Server $vcConn -ErrorAction SilentlyContinue
            if ($existing){
                $module.msg += "[re-add] Host '$esxi_host' already present"
                $module.status = "NoChange"
                $module.changed = $false
                Exit-Json
            }

            $dcObj = Get-Datacenter -Name $target_datacenter -Server $vcConn -ErrorAction Stop
            if ($target_cluster) {
                $clusterObj = Get-Cluster -Server $vcConn -Location $dcObj | Where-Object { $_.Name -eq $target_cluster }
                if (-not $clusterObj) { throw "Cluster '$target_cluster' not found in Datacenter '$target_datacenter'." }
                $locationObj = $clusterObj
                $module.msg += "[re-add] Target location: DC='$target_datacenter', Cluster='$target_cluster'`n"
            } else {
                $locationObj = $dcObj
                $module.msg += "[re-add] Target location: DC='$target_datacenter' (no cluster)`n"
            }

            $addParams = @{
                Name        = $esxi_host
                Location    = $locationObj
                User        = $esxi_user
                Password    = $esxi_password
                Force       = $true
                ErrorAction = 'Stop'
              }
              
              $vmhost = Add-VMHost @addParams
              
              Set-VMHost -VMHost $vmhost -State Connected -ErrorAction SilentlyContinue | Out-Null
              $module.msg += "[re-add] ESXi '$esxi_host' re-added successfully.`n"
              $module.status = "Success"
              $module.changed = $true
              Exit-Json $module      
        }
        catch {
            $module.failed = $true
            $module.status = "Error"
            $module.msg   += "[re-add] Failed: $($_.Exception.Message)`n"
            Exit-Json $module
        }
    }
    else {
        update-error "Unsupported esxi_action: $esxi_action"
        Exit-Json $module
    }

} 
catch {
    update-error "Unexpected error in esxi_cert_mgmt"
    Exit-Json $module
}

finally {
    if ($VIServer) {
        try {
            Disconnect-VIServer -Server $vcConn -Confirm:$false -ErrorAction SilentlyContinue
            $module.msg += "Disconnected from vCenter."
        } catch { }
    }
}

# --- Default message ---
if (-not $module.msg -or $module.msg.Trim() -eq "") {
    if ($module.failed) {
        $module.msg = "An error occurred, but no specific error message was provided."
    } elseif ($module.changed) {
        $module.msg = "The operation completed successfully and changes were made."
    } else {
        $module.msg = "The operation completed successfully with no changes."
    }
}

# --- standard output ---
if ($module.failed) {
    $module.msg = "ESXi Certificate Management FAILED. " + $module.msg
} elseif ($module.changed) {
    $module.msg = "ESXi Certificate Management SUCCEEDED with changes. " + $module.msg
} else {
    $module.msg = "ESXi Certificate Management SUCCEEDED (read-only or no change). " + $module.msg
}

Exit-Json $module