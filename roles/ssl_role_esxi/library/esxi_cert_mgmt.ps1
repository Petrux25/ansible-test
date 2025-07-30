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
            $esxi = Get-VMHost 'esx001.local.com'


            $stoppedvms = @()
            $vmstopoweroff = Get-VM -Server $vcConn | Where-Object { $_.VMHost -eq $esxi -and $_.PowerState -eq "PoweredOn" }
            foreach ($vm in $vmstopoweroff) { 
                Write-Host "Turning off VM: $($vm.Name)" 
                Stop-VM -VM $vm -Confirm:$false
                $stoppedvms += $vm.Name
            }

    
            do {
                $poweredOnVMs = Get-VM -Server $vcConn | Where-Object { $_.VMHost -eq $esxi -and $_.PowerState -eq "PoweredOn" }
                if ($poweredOnVMs.Count -gt 0) {
                    Write-Host "Watiting for VMs to be powered off..."
                    Start-Sleep -Seconds 5
                }
            } while ($poweredOnVMs.Count -gt 0)

            Set-VMHost -VMHost $esxi -State Maintenance
            $module.msg += "ESXi host $esxi_host set to maintenance mode. "

            $module.data = $stoppedvms
            
            Disconnect-VIServer -Server $vcConn -Confirm:$false
            $module.changed = $true
            $module.status = "Success"
        }
        catch {
            update-error "Failed to put ESXi host into maintenance mode"
            Exit-Json $module
        }
    }

    else {
        update-error "Unsupported esxi_action: $esxi_action"
        Exit-Json $module
    }

} catch {
    update-error "Unexpected error in esxi_cert_mgmt"
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
} elseif ($module.changed) {
    $module.msg = "ESXi Certificate Management SUCCEEDED with changes. " + $module.msg
} else {
    $module.msg = "ESXi Certificate Management SUCCEEDED (read-only or no change). " + $module.msg
}

Exit-Json $module