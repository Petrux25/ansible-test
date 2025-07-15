#!powershell
#Requires -Module Ansible.ModuleUtils.Legacy
#Requires -Module VMware.PowerCLI

$ErrorActionPreference = "Stop"

# --- Read and parse incoming parameters ---
$params = Parse-Args $args -supports_check_mode $true
$vcenter_action    = Get-AnsibleParam -obj $params -name "vcenter_action" -type "str" -failifempty $true
$vcenter_server    = Get-AnsibleParam -obj $params -name "vcenter_server" -type "str" -failifempty ($vcenter_action -ne "read_cert")
$vcenter_user      = Get-AnsibleParam -obj $params -name "vcenter_user" -type "str" -failifempty ($vcenter_action -ne "read_cert")
$vcenter_password  = Get-AnsibleParam -obj $params -name "vcenter_password" -type "str" -secret $true -failifempty ($vcenter_action -ne "read_cert")
$ca_cert_path      = Get-AnsibleParam -obj $params -name "ca_cert_path" -type "str" -failifempty ($vcenter_action -eq "add_CA")
$machine_ssl_cert_path = Get-AnsibleParam -obj $params -name "machine_ssl_cert_path" -type "str" -failifempty ($vcenter_action -eq "change_certificate")

# --- Result object ---
$module = New-Object psobject @{
    result  = ""
    changed = $false
    msg     = ""
    status  = ""
    FailJson= @()
    failed  = $false
    data    = ""
}

function update-error([string] $description) {
    $module.status = 'Error'
    $module.msg = "Error - $description. $($_.Exception.Message)"
    $module.FailJson = ("Error: Stage: $description", $_)
    $module.failed = $true
}

$VIServer = $null

try {
    if ($vcenter_action -ne "read_cert") {
        try {
            Import-Module VMware.PowerCLI -ErrorAction Stop
        } catch {
            update-error "Failed to import VMware.PowerCLI."
            Exit-Json $module
        }
        Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null

        $module.msg += "Connecting to vCenter Server '$vcenter_server'... "
        $VIServer = Connect-VIServer -Server $vcenter_server -User $vcenter_user -Password $vcenter_password -ErrorAction Stop
        $module.msg += "Connected. "
    }

    # --- Actions ---
    if ($vcenter_action -eq "connect") {
        $module.msg += "vCenter connection established. "
        $module.changed = $false
        $module.status = "Success"
    }

    elseif ($vcenter_action -eq "add_CA") {
        try {
            $module.msg += "Adding CA from '$ca_cert_path'... "
            $trustedCertChain = Get-Content $ca_cert_path -Raw
            Add-VITrustedCertificate -PemCertificateOrChain $trustedCertChain -VCenterOnly
            $module.msg += "CA added to vCenter trusted store. "
            $module.changed = $true
            $module.status = "Success"
        }
        catch {
            update-error "Failed to add CA certificate."
            Exit-Json $module
        }
    }

    elseif ($vcenter_action -eq "replace_certificate") {
        try {
            $module.msg += "Replacing vCenter Machine SSL certificate from '$machine_ssl_cert_path'... "
            $vcCert = Get-Content $machine_ssl_cert_path -Raw
            Set-VIMachineCertificate -PemCertificate $vcCert
            $module.msg += "Machine SSL certificate replaced successfully. A reboot may be required. "
            $module.changed = $true
            $module.status = "Success"
        }
        catch {
            update-error "Failed to change vCenter Machine SSL certificate."
            Exit-Json $module
        }
    }

    elseif ($vcenter_action -eq "read_cert") {
        try {
            $module.msg += "Reading vCenter certificate info... "
            $certs = Get-VIMachineCertificate -VCenterOnly
            $module.data = $certs
            $module.changed = $false
            $module.status = "Success"
            $module.msg += "Certificate info read successfully. "
        }
        catch {
            update-error "Failed to read vCenter certificate."
            Exit-Json $module
        }
    }

    else {
        update-error "Unsupported vcenter_action: '$vcenter_action'"
    }
}
catch {
    update-error "An unexpected error occurred. $($_.Exception.Message) ScriptStackTrace: $($_.ScriptStackTrace)"
    Exit-Json $module
}
finally {
    if ($VIServer) {
        try {
            Disconnect-VIServer -Server $VIServer -Confirm:$false -ErrorAction SilentlyContinue
            $module.msg += "Disconnected from vCenter."
        } catch {Exit-Json $module}
    }
}

# --- Ensure msg is never empty ---
if (-not $module.msg -or $module.msg.Trim() -eq "") {
    if ($module.failed) {
        $module.msg = "An error occurred, but no specific error message was provided."
    } elseif ($module.changed) {
        $module.msg = "The operation completed successfully and changes were made."
    } else {
        $module.msg = "The operation completed successfully with no changes."
    }
}

# --- Standardize final output ---
if ($module.failed) {
    $module.msg = "vCenter Certificate Management FAILED. " + $module.msg
} elseif ($module.changed) {
    $module.msg = "vCenter Certificate Management SUCCEEDED with changes. " + $module.msg
} else {
    $module.msg = "vCenter Certificate Management SUCCEEDED (read-only or no change). " + $module.msg
}

Exit-Json $module
