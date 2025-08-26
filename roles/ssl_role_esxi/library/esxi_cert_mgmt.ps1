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
$target_datacenter = Get-AnsibleParam -obj $params -name "target_datacenter" -type "str" -failifempty $false
$target_cluster = Get-AnsibleParam -obj $params -name "target_cluster" -type "str" -failifempty $false
$vms_to_power_on = Get-AnsibleParam -obj $params -name "vms_to_power_on" -type "list" -default @()




function update-error([string] $description) {
    $module.status = 'Error'
    $module.msg = "Error - $description. $($_.Exception.Message)"
    $module.failed = $true
}

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
        $EnteredMaintenance = $false
        $stoppedvms = @()
        try {
            Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
            $vcConn = Connect-VIServer -Server $vcenter_server -User $vcenter_user -Password $vcenter_password -ErrorAction Stop
            
            $esxi = Get-VMHost -Name $esxi_host
            if (-not $esxi){ throw "Host $esxi_host not found in vCenter"
            }

            if ($esxi.ConnectionState -eq "Maintenance") {
                $module.msg += "Host $esxi_host is already in maintenance mode. Now proceeding to remove it from vCenter."
                $module.status += "NoChange"
                $module.changed = $false
                Exit-Json $module
            }
            
            #turning off vms
            $vmstopoweroff = Get-VM -Server $vcConn | Where-Object { $_.VMHost -eq $esxi -and $_.PowerState -eq "PoweredOn" }

            if ($vmstopoweroff) {
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
                } else {
                    Write-Host "No VMs powered on found in host"
                }
                
                Write-Host "Starting to configure maintenance mode..."
                Set-VMHost -VMHost $esxi -State Maintenance
                $EnteredMaintenance = $true


                $module.msg += "ESXi host $esxi_host set to maintenance mode. "
                $module.data = @{
                    PoweredOffVMs = $stoppedvms
                }
                $module.changed = $true
                $module.status = "Success"
                Write-Host "The following VMs were turned off: $($stoppedvms -join ', ')"
                
        }
        catch {
            update-error "Failed to put ESXi host into maintenance mode"
            $module.msg += "Rollback attempt: "
            try {
                if ($vcConn) {
                    $vmhost = Get-VMHost -Name $esxi_host -Server $vcConn -ErrorAction SilentlyContinue
                    if ($vmhost -and $EnteredMaintenance) {
                        Write-Host "Exiting maintenance mode on $esxi_host"
                        Set-VMHost -VMHost $vmhost -State Connected -Confirm:$false | Out-Null
                        $module.msg += "Exited maintenance mode on $esxi_host. "
                    }
                
                    if ($stoppedvms.Count -gt 0) {
                        foreach ($vmName in $stoppedvms) {
                            $vmToStart = Get-VM -Name $vmName -Server $vcConn -ErrorAction SilentlyContinue
                            if ($vmToStart) {
                                Start-VM -VM $vmToStart -Confirm:$false
                            }
                        }
                        $module.msg += "Attempted to start power on VMs "
                    }
                }
            $module.msg += "Rollback finished"
            }catch {
                $module.msg += "Rollback failed: $($_.Exception.Message)"
            }

            Exit-Json $module     
        }
    }

    elseif ($esxi_action -eq "remove") {
        $hostRemoved = $false

        try {

            Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
            $vcConn = Connect-VIServer -Server $vcenter_server -User $vcenter_user -Password $vcenter_password -ErrorAction Stop
            
            $vmhost = Get-VMHost -Name $esxi_host -Server $vcConn
            if (-not $vmhost) {
                throw "Host '$esxi_host' not found in vCenter"
            }
            if ($vmhost.State -ne "Maintenance") {
                throw "Host '$($vmhost.Name)' is not in maintenance mode"
            }
            
            #Datacenter y cluster info
            $dcObj = Get-Datacenter -VMHost $vmhost -Server $vcConn
            $clusterObj = Get-Cluster -VMHost $vmhost -Server $vcConn -ErrorAction SilentlyContinue

            $dcName = ($dcObj | Select-Object -First 1 -ExpandProperty Name)
            $clusterName = if ($clusterObj) { ($clusterObj | Select-Object -First 1 -ExpandProperty Name)} else { "" }

            if (-not $module.data) { $module.data = @{} }

            $module.data.HostLocation = @{
                Datacenter = $dcName
                Cluster = $clusterName
            }

            Write-Host "Host location: "
            Write-Host "Datacenter: $dcName"
            Write-Host "Cluster: $clusterName"

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
            $hostRemoved = $true
            Write-Host "ESXi has been removed successfully"

            $module.msg += "ESXi $esxi_host has been removed from vCenter."
            $module.changed = $true
            $module.status = "Success"
        }
        catch {
            update-error "Failed to remove $esxi_host from vCenter"
            if (-not $hostRemoved) {
                $module.msg += "Rollback attempt: "
                try {
                    if ($vcConn) {
                        $vmhost = Get-VMHost -Name $esxi_host -Server $vcConn -ErrorAction SilentlyContinue
                        if ($vmhost -and $vmhost.State -eq "Maintenance") {
                            Set-VMHost -VMHost $vmhost -State Connected -Confirm:$false | Out-Null
                            $module.msg += "Host '$esxi_host' has taken out of maintenance mode."
                        }
                        if ($vms_to_power_on.Count -gt 0) {
                            foreach ($vmName in $vms_to_power_on) {
                                $vmToStart = Get-VM -Name $vmName -Server $vcConn -ErrorAction SilentlyContinue
                                if ($vmToStart) {Start-VM -VM $vmToStart -Confirm:$false | Out-Null }
                            }
                            $module.msg += "Attempted to power on VMs"
                        }
                    }
                    $module.msg += "Rollback finished."
                } catch {
                    $module.msg += "Error during rollback: $($_.Exception.Message)"
                }
            } else {
                $module.msg += "Critical: Host already removed. Manual intervention required."
            }
            Exit-Json $module
        }
    }

    # --- Replace ESXi certificate ---
    elseif ($esxi_action -eq "replace_cert") {
        try {

            if (-not $esxi_host -or $esxi_host.Trim() -eq "")      { throw "esxi_host vacío" }
            if (-not $esxi_user -or $esxi_user.Trim() -eq "")      { throw "esxi_user vacío" }
            if (-not $esxi_password -or $esxi_password -eq "")     { throw "esxi_password vacío" }
            if (-not $esxi_cert_path -or -not (Test-Path $esxi_cert_path)) { throw "Cert no existe: $esxi_cert_path" }

            Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null

            Connect-VIServer -Server $vcenter_server -User $vcenter_user -Password $vcenter_password -ErrorAction Stop
            
            # 1. Conectar directamente al host ESXi
            Write-Host "Connecting directly to ESXi host: $esxi_host"

            $securePassword = ConvertTo-SecureString $esxi_password -AsPlainText -Force

            $credentials =  [PSCredential]::New($esxi_user,$securePassword)

            $esxConnection = Connect-VIServer -Server $esxi_host -Credential $credentials -ErrorAction Stop -Force

            # 2. Leer el nuevo certificado desde el archivo .pem
            Write-Host "Reading certificate from: $esxi_cert_path"
            $esxCertificatePem = Get-Content $esxi_cert_path -Raw
            
            # 3. Obtener el objeto del host para el comando
            $targetEsxHost = Get-VMHost -Name $esxi_host -Server $esxConnection
            
            # 4. Establecer el nuevo certificado de máquina en el host
            Write-Host "Setting new machine certificate on $esxi_host..."
            Set-VIMachineCertificate -PemCertificate $esxCertificatePem -VMHost $targetEsxHost -Confirm:$false | Out-Null
            
            # 5. Reiniciar el host para que el cambio de certificado tenga efecto (mandatorio)
            Write-Host "Restarting host $esxi_host to apply certificate changes..."
            Restart-VMHost -VMHost $targetEsxHost -Confirm:$false | Out-Null

            $module.msg = "New certificate has been set on $esxi_host. A host reboot has been initiated."
            $module.changed = $true
            $module.status = "Success"

            Disconnect-VIServer $esxConnection -Confirm:$false
                        
        } catch {
            update-error "Failed to replace certificate on ESXi host $esxi_host"
            # Intentar desconectar si la conexión aún existe
            
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
            $module.msg += "[re-add] Connected to vCenter $vcenter_server "


            $existing = Get-VMHost -Name $esxi_host -Server $vcConn -ErrorAction SilentlyContinue
            if ($existing){
                Set-VMHost -VMHost $existing -State Connected -ErrorAction SilentlyContinue | Out-Null
                $module.msg += "[re-add] Host '$esxi_host' already present"
                $module.status = "NoChange"
                $module.changed = $false
                Exit-Json $module
            }
            
            $dcObj = Get-Datacenter -Name $target_datacenter -Server $vcConn -ErrorAction Stop
            if ($target_cluster) {
                $clusterObj = Get-Cluster -Server $vcConn -Location $dcObj | Where-Object { $_.Name -eq $target_cluster }
                if (-not $clusterObj) { Write-Host "Cluster '$target_cluster' not found in Datacenter '$target_datacenter'." }
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

    elseif ($esxi_action -eq "turn_on_vms") {
        try {
            if ($vms_to_power_on.Count -eq 0) {
                Write-Host "No VMs to power on."
            }
            $vcConn = Connect-VIServer -Server $vcenter_server -User $vcenter_user -Password $vcenter_password -ErrorAction Stop
            $module.msg = "Attempting to power on VMs: $($vms_to_power_on -join ', ')"
            $poweredOnCount= 0
            
            foreach ($vmName in $vms_to_power_on){
                $vm = Get-VM -Name $vmName.Trim() -Server $vcConn -ErrorAction SilentlyContinue
                if ($vm) {
                    if ($vm.PowerState -eq 'PoweredOff') {
                        Start-VM -VM $vm -Confirm:$false | Out-Null
                        $module.msg += "VM '$vmName' powered on. "
                        $poweredOnCount++
                    } else {
                        $module.msg += "VM '$vmName' is already powered on. "
                    }
                } else { 
                    $module.msg += "VM '$vmName' not found in vCenter. "  
                }
            }
            if ($poweredOnCount -gt 0) {
                $module.changed = $true
            }
            $module.status = "Success"
        }
        catch {
            update-error "Failed to power on VMs"
            Exit-Json $module
        }
    }
    else {
        update-error "Unsupported esxi_action: $esxi_action"
        Exit-Json $module
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
} else {
    $module.msg = "ESXi Certificate Management SUCCEEDED. " + $module.msg
}

Exit-Json $module