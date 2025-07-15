#!powershell
#Requires -Module Ansible.ModuleUtils.Legacy
#Requires -Module VMware.PowerCLI

$ErrorActionPreference = "Stop"

# --- Read and parse incoming parameters ---
$params           = Parse-Args $args -supports_check_mode $true
$esxi_action      = Get-AnsibleParam -obj $params -name "esxi_action" -type "str" -failifempty $true
$esxi_host        = Get-AnsibleParam -obj $params -name "esxi_host" -type "str" -failifempty $true
$esxi_user        = Get-AnsibleParam -obj $params -name "esxi_user" -type "str" -failifempty ($esxi_action -in @("connect","change_machine_ssl_cert"))
$esxi_password    = Get-AnsibleParam -obj $params -name "esxi_password" -type "str" -secret $true -failifempty ($esxi_action -in @("connect","change_machine_ssl_cert"))
$esxi_cert_path   = Get-AnsibleParam -obj $params -name "esxi_cert_path" -type "str" -failifempty ($esxi_action -eq "change_machine_ssl_cert")
$vcenter_server   = Get-AnsibleParam -obj $params -name "vcenter_server" -type "str" -failifempty ($esxi_action -in @("remove","re-add"))
$vcenter_user     = Get-AnsibleParam -obj $params -name "vcenter_user" -type "str" -failifempty ($esxi_action -in @("remove","re-add"))
$vcenter_password = Get-AnsibleParam -obj $params -name "vcenter_password" -type "str" -secret $true -failifempty ($esxi_action -in @("remove","re-add"))
$esxi_location    = Get-AnsibleParam -obj $params -name "esxi_location" -type "str" -failifempty ($esxi_action -eq "re-add")

# Result object 
$module = New-Object psobject @{
    result  = ""
    changed = $false
    msg     = ""
    status  = ""
    failed  = $false
    data    = ""
}

function update-error([string] $description) {
    $module.status = 'Error'
    $module.msg = "Error - $description. $($_.Exception.Message)"
    $module.failed = $true
}

try {

    # --- Set vCenter in modo custom ---
    if ($esxi_action -eq "custom_mode") {
        try {
            Import-Module VMware.PowerCLI -ErrorAction Stop
            Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
            $vcConn = Connect-VIServer -Server $vcenter_server -User $vcenter_user -Password $vcenter_password -ErrorAction Stop
            $module.msg += "Connected to vCenter. "
            $certModeSetting = Get-AdvancedSetting -Entity $vcConn -Name "vpxd.certmgmt.mode"
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
            Import-Module VMware.PowerCLI -ErrorAction Stop
            Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
            $vcConn = Connect-VIServer -Server $vcenter_server -User $vcenter_user -Password $vcenter_password -ErrorAction Stop
            $esxi = Get-VMHost -Name $esxi_host
            Set-VMHost -VMHost $esxi -State Maintenance -Confirm:$false
            $module.msg += "ESXi host $esxi_host set to maintenance mode. "
            Disconnect-VIServer -Server $vcConn -Confirm:$false
            $module.changed = $true
            $module.status = "Success"
        } catch {
            update-error "Failed to put ESXi host into maintenance mode"
            Exit-Json $module
        }
    }

    # --- Remove ESXi from vCenter ---
    elseif ($esxi_action -eq "remove") {
        try {
            Import-Module VMware.PowerCLI -ErrorAction Stop
            Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
            $vcConn = Connect-VIServer -Server $vcenter_server -User $vcenter_user -Password $vcenter_password -ErrorAction Stop
            $esxi = Get-VMHost -Name $esxi_host
            Remove-VMHost -VMHost $esxi -Confirm:$false
            $module.msg += "ESXi host $esxi_host removed from vCenter. "
            Disconnect-VIServer -Server $vcConn -Confirm:$false
            $module.changed = $true
            $module.status = "Success"
        } catch {
            update-error "Failed to remove ESXi host from vCenter"
            Exit-Json $module
        }
    }

    # --- Connect to ESXi, change certificate and reboot ---
    elseif ($esxi_action -eq "replace_cert") {
        try {
            Import-Module VMware.PowerCLI -ErrorAction Stop
            Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
            $esxConn = Connect-VIServer -Server $esxi_host -User $esxi_user -Password $esxi_password -ErrorAction Stop
            $certContent = Get-Content $esxi_cert_path -Raw
            $esxiObj = Get-VMHost -Name $esxi_host
            Set-VIMachineCertificate -PemCertificate $certContent -VMHost $esxiObj | Out-Null
            $module.msg += "Replaced machine SSL certificate on $esxi_host. "
            Restart-VMHost -VMHost $esxiObj -Confirm:$false
            $module.msg += "Restarted ESXi host $esxi_host. "
            Disconnect-VIServer -Server $esxConn -Confirm:$false
            $module.changed = $true
            $module.status = "Success"
        } catch {
            update-error "Failed to replace certificate or restart ESXi host"
            Exit-Json $module
        }
    }

    # --- Re-add esxi ---
    elseif ($esxi_action -eq "re-add") {
        try {
            Import-Module VMware.PowerCLI -ErrorAction Stop
            Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
            $vcConn = Connect-VIServer -Server $vcenter_server -User $vcenter_user -Password $vcenter_password -ErrorAction Stop
            $datacenter = Get-Datacenter -Name $esxi_location
            $esxAdded = Add-VMHost -Name $esxi_host -Location $datacenter -User $esxi_user -Password $esxi_password -Force
            Set-VMHost -VMHost $esxAdded -State Connected
            $module.msg += "Re-added ESXi host $esxi_host to vCenter in datacenter $esxi_location and set to Connected. "
            Disconnect-VIServer -Server $vcConn -Confirm:$false
            $module.changed = $true
            $module.status = "Success"
        } catch {
            update-error "Failed to re-add ESXi host to vCenter"
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