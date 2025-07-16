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
    Import-Module VMware.PowerCLI -ErrorAction Stop
    Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null

    # 1. Conectarse SIEMPRE al principio
    $VIServer = Connect-VIServer -Server $vcenter_server -User $vcenter_user -Password $vcenter_password -ErrorAction Stop
    $module.msg += "Connected to vCenter. "

    # 2. Acción
    if ($vcenter_action -eq "add_CA") {
        $trustedCertChain = Get-Content $ca_cert_path -Raw
        Add-VITrustedCertificate -PemCertificateOrChain $trustedCertChain -VCenterOnly
        $module.msg += "CA added to vCenter trusted store. "
        $module.changed = $true
        $module.status = "Success"
    }
    elseif ($vcenter_action -eq "replace_certificate") {
        $vcCert = Get-Content $machine_ssl_cert_path -Raw
        Set-VIMachineCertificate -PemCertificate $vcCert
        $module.msg += "Machine SSL certificate replaced successfully. "
        $module.changed = $true
        $module.status = "Success"
    }
    else {
        update-error "Unsupported vcenter_action: '$vcenter_action'"
    }
}
catch {
    update-error "Error in vCenter action execution"
    Exit-Json $module
}
finally {
    if ($VIServer) {
        try {
            Disconnect-VIServer -Server $VIServer -Confirm:$false -ErrorAction SilentlyContinue
            $module.msg += "Disconnected from vCenter."
        } catch { }
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
