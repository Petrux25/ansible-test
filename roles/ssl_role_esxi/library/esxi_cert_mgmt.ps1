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

function Set-VCenterCertMode {
    param(
        [Parameter(Mandatory=$true)][psobject]$module,
        [Parameter(Mandatory=$true)][string]$vcenter_server,
        [Parameter(Mandatory=$true)][string]$vcenter_user,
        [Parameter(Mandatory=$true)][securestring]$vcenter_password
    )
    try{
        $vcConn = Connect-VIServer -Server $vcenter_server -User $vcenter_user -Password $vcenter_password -ErrorAction Stop
        $module.msg += "Connected to vCenter. "
        $certModeSetting = Get-AdvancedSetting -Name "vpxd.certmgmt.mode" -Entity $vcConn -Server $vcConn
        Set-AdvancedSetting -AdvancedSetting $certModeSetting -Value "custom" -Confirm:$false
        $module.msg += "Set vpxd.certmgmt.mode to 'custom'. "
        $module.changed = $true
        $module.status = "Success"
    }
    catch{
        update-error "Failed to set vCenter to custom mode"
        throw
    }
    finally {
        if ($vcConn) {
            Disconnect-VIServer -Server $vcConn -Confirm:$false
        }
    }
}

function Enter-MaintenanceMode {
    param(
        [Parameter(Mandatory=$true)][psobject]$module,
        [Parameter(Mandatory=$true)][string]$esxi_host,
        [Parameter(Mandatory=$true)][string]$vcenter_server,
        [Parameter(Mandatory=$true)][string]$vcenter_user,
        [Parameter(Mandatory=$true)][securestring]$vcenter_password
    )
   
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
                return 
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
                $module.data = @{ PoweredOffVMs = $stoppedvms }
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

            throw    
        } 
        finally{
            if ($vcConn) {
                Disconnect-VIServer -Server $vcConn -Confirm:$false | Out-Null
            }
        }
}

function Remove-VMFromVCenter {

    param (
        [Parameter(Mandatory=$true)][psobject]$module,
        [Parameter(Mandatory=$true)][string]$vcenter_server,
        [Parameter(Mandatory=$true)][string]$vcenter_user,
        [Parameter(Mandatory=$true)][securestring]$vcenter_password,
        [Parameter(Mandatory=$true)][string]$esxi_host,
        [Parameter(Mandatory=$true)][array]$vms_to_power_on
        
    )

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
            Throw
    }
    finally {
        if ($esxConnection) {
            Disconnect-VIServer -Server $esxConnection -Confirm:$false | Out-Null
        }
        if ($vcConn) {
            Disconnect-VIServer -Server $vcConn -Confirm:$false | Out-Null
        }
    }
}

function Update-Cert{
    param(
        [Parameter(Mandatory=$true)][psobject]$module,
        [Parameter(Mandatory=$true)][string]$vcenter_server,
        [Parameter(Mandatory=$true)][string]$vcenter_user,
        [Parameter(Mandatory=$true)][securestring]$vcenter_password,
        [Parameter(Mandatory=$true)][string]$esxi_host,
        [Parameter(Mandatory=$true)][string]$esxi_user,
        [Parameter(Mandatory=$true)][securestring]$esxi_password,
        [Parameter(Mandatory=$true)][string]$esxi_cert_path,
        [Parameter(Mandatory=$true)][string]$target_datacenter,
        [Parameter(Mandatory=$true)][string]$target_cluster,
        [Parameter(Mandatory=$true)][array]$vms_to_power_on
    )
    $cert_replaced = $false
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
            $cert_replaced = $true

            # 5. Reiniciar el host para que el cambio de certificado tenga efecto (mandatorio)
            Write-Host "Restarting host $esxi_host to apply certificate changes..."
            Restart-VMHost -VMHost $targetEsxHost -Confirm:$false | Out-Null

            $module.msg = "New certificate has been set on $esxi_host. A host reboot has been initiated."
            $module.changed = $true
            $module.status = "Success"
    }
    catch {
        update-error "Failed to replace certificate on ESXi host $esxi_host"
        if (-not $cert_replaced) {
                $module.msg += "Certificate was not replaced. Rollback attempt started."
                # Intentar revertir los cambios realizados
                try {
                    Write-Host "Attempting to rollback changes on $esxi_host..."
                    Write-Host "Reconnecting to vCenter $vcenter_server..."
                    $vcConnRB = Connect-VIServer -Server $vcenter_server -User $vcenter_user -Password $vcenter_password -ErrorAction Stop

                    #Re-adding host

                    Write-Host "Rollback: Attempting to re-add host..."
                    $existingHost = Get-VMHost -Name $esxi_host -Server $vcConnRB -ErrorAction SilentlyContinue
                    if ($existingHost) {
                        $module.msg += "Host '$esxi_host' already present in vCenter, skipping re-add"
                        $vmhostRB = $existingHost
                    } else {
                        if (-not $target_datacenter) {throw "No location found for ESXi host in module data"}
                        $dcObj = Get-Datacenter -Name $target_datacenter -Server $vcConnRB -ErrorAction Stop
                        $locationObj = $dcObj
                        if ($target_cluster){
                            $clusterObj = Get-Cluster -Name $target_cluster -Server $vcConnRB -Location $dcObj -ErrorAction Stop
                            if ($clusterObj) { $locationObj = $clusterObj }
                        }
                        $vmhostRB = Add-VMHost -Name $esxi_host -Location $locationObj -User $esxi_user -Password $esxi_password -Force -ErrorAction Stop -Confirm:$false
                        Write-Host "Host $esxi_host re-added to vCenter."
                    }
                    # Maintenance mode off
                    Write-Host "Rollback: Taking host out of maintenance mode"
                    Set-VMHost -VMHost $vmhostRB -State Connected -ErrorAction Stop -Confirm:$false | Out-Null
                    $module.msg += "Host $($esxi_host) is no longer in maintenance mode."

                    #Turning on VMs

                    Write-Host "Rollback: Attempting to power on VMs"
                    if ($vms_to_power_on -and $vms_to_power_on.Count -gt 0) {
                        foreach ($vmName in $vms_to_power_on) {
                            $vmToStart = Get-VM -Name $vmName.Trim() -Server $vcConnRB -ErrorAction SilentlyContinue
                            if ($vmToStart -and $vmToStart.PowerState -eq 'PoweredOff'){
                                Start-VM -VM $vmToStart -Confirm:$false | Out-Null
                            }
                        }
                        $module.msg += "Attempted to power on specified VMs."
                    } else {
                        $module.msg += "No VMs to power on."
                    }
                    Disconnect-VIServer -Server $vcConnRB -Confirm:$false
                    $module.msg += "Rollback completed."

                } catch {
                    $module.msg += "Critical: Rollback failed: $($_.Exception.Message)"
                }
            } elseif ($cert_replaced) {
                $module.msg += "Critical: Certificate was replaced but error occurred after that. Host has been restarted. Manual verification required."
            }       
            Throw
    }
    finally {
        if ($esxConnection) {
            Disconnect-VIServer -Server $esxConnection -Confirm:$false | Out-Null
        }
        if ($vcConnRB) {
            Disconnect-VIServer -Server $vcConnRB -Confirm:$false | Out-Null
        }
    }
}

function Add-ESXHostToVC {
    param (
        [Parameter(Mandatory)][psobject]$module,
        [Parameter(Mandatory)][string]$vcenter_server,
        [Parameter(Mandatory)][string]$vcenter_user,
        [Parameter(Mandatory)][string]$vcenter_password,
        [Parameter(Mandatory)][string]$esxi_host,
        [Parameter(Mandatory)][string]$esxi_user,
        [Parameter(Mandatory)][string]$esxi_password,
        [Parameter(Mandatory)][string]$target_datacenter,
        [Parameter(Mandatory)][string]$target_cluster,
        [Parameter(Mandatory)][array]$vms_to_power_on
    )
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
                return
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
    }
    catch {
        update-error "Failed to re-add ESXi host"
        $module.failed = $true
        $module.status = "Error"
        $module.msg   += "[re-add] Failed: $($_.Exception.Message)`n"
        return
        }
    finally {
        if ($vcConn) {
            Disconnect-VIServer -Server $vcConn -Confirm:$false | Out-Null
        }
    }
}

function Start-VMs{
    param(
        [Parameter(Mandatory)][psobject]$module,
        [Parameter(Mandatory)][string]$vcenter_server,
        [Parameter(Mandatory)][string]$vcenter_user,
        [Parameter(Mandatory)][string]$vcenter_password,
        [Parameter(Mandatory)][array]$vms_to_power_on

    )

    try {
        if ($vms_to_power_on.Count -eq 0) {
                $module.msg = "No VMs to power on."
                return
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
        throw
    }
    finally {
        if ($vcConn) {
            Disconnect-VIServer -Server $vcConn -Confirm:$false | Out-Null
        }
    }


}


    # --- Set vCenter in modo custom ---
    if ($esxi_action -eq "custom_mode") {
        try {
            Set-VCenterCertMode -module $module -vcenter_server $vcenter_server -vcenter_user $vcenter_user -vcenter_password $vcenter_password  
        } catch {
            Exit-Json $module
        }
    }

    # --- ESX in maintenance mode ---
    elseif ($esxi_action -eq "maintenance") {
        try {
            Enter-MaintenanceMode -module $module -vcenter_server $vcenter_server -vcenter_user $vcenter_user -vcenter_password $vcenter_password -esxi_host $esxi_host
        }
        catch {
            Exit-Json $module
        }
        
    }

    elseif ($esxi_action -eq "remove") {
        $hostRemoved = $false

        try {
            Remove-VMFromVCenter -module $module 
            -vcenter_server $vcenter_server 
            -vcenter_user $vcenter_user 
            -vcenter_password $vcenter_password 
            -esxi_host $esxi_host 
            -vms_to_power_on $vms_to_power_on 
        }
        catch {
            Exit-Json $module
            
        }
    }

    # --- Replace ESXi certificate ---
    elseif ($esxi_action -eq "replace_cert") {
        
        try {
            Update-Cert -module $module 
            -vcenter_server $vcenter_server 
            -vcenter_user $vcenter_user 
            -vcenter_password $vcenter_password 
            -esxi_host $esxi_host 
            -esxi_user $esxi_user 
            -esxi_password $esxi_password 
            -esxi_cert_path $esxi_cert_path 
            -vms_to_power_on $vms_to_power_on 
            -target_datacenter $target_datacenter 
            -target_cluster $target_cluster

        } catch {
            Exit-Json $module 
        }
    }

    elseif ($esxi_action -eq "re-add") {

        try {
            Add-ESXHostToVC -module $module 
            -vcenter_server $vcenter_server 
            -vcenter_user $vcenter_user 
            -vcenter_password $vcenter_password 
            -esxi_host $esxi_host 
            -esxi_user $esxi_user 
            -esxi_password $esxi_password 
            -target_datacenter $target_datacenter 
            -target_cluster $target_cluster
        }
        catch {
            Exit-Json $module
        }
    }

    elseif ($esxi_action -eq "turn_on_vms") {
        try {
            Start-VMs -vms_to_power_on $vms_to_power_on 
            -vcenter_server $vcenter_server 
            -vcenter_user $vcenter_user 
            -vcenter_password $vcenter_password
        }
        catch {
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