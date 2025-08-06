#Requires -Module VMware.PowerCLI
#Requires -Module Ansible.ModuleUtils.Legacy

$ErrorActionPreference =  "Stop"

$params = Parse-Args $args -supports_check_mode $true
$vcenter_action = Get-AnsibleParam -obj $params -name "vcenter_action" -type "str" -failifempty $true
$vcenter_server = Get-AnsibleParam -obj $params -name "vcenter_server" -type "str" -failifempty $true
$vcenter_user = Get-AnsibleParam -obj $params -name "vcenter_user" -type "str" -failifempty $true
$vcenter_password = Get-AnsibleParam -obj $params -name "vcenter_password" -type "str" -secret $true -failifempty $true
$ca_cert_path = Get-AnsibleParam -obj $params -name "ca_cert_path" -type "str" -failifempty $false
$machine_ssl_cert_path = Get-AnsibleParam -obj $params -name "machine_ssl_cert_path" -type "str" -failifempty $false

$module = New-Object psobject @{
    result = ''
    changed = $false
    msg = ""
    status = ""
    failed = $false 
    FailJson = ""
    data = ""
}

function update-error([string] $description) {
    $module.status = 'Error'
    $module.msg = "Error - $description. $($_.Exception.Message)"
    $module.FailJson = ("Error: Stage: $description", $_)
    $module.failed = $true
}

$variables = @{
    Action    = $vcenter_action
    Server    = $vcenter_server
    User      = $vcenter_user
    CA_Path   = $ca_cert_path
    Cert_Path = $machine_ssl_cert_path
}

$module.data = $variables 

$VIServer = $null

if ($vcenter_action -eq "connect") {
    try {
        $module.msg += "Trying to connect to vCenter \n"
        Connect-VIServer -Server $vcenter_server -User $vcenter_user -Password $vcenter_password -ErrorAction Stop
        $module.msg += "Successfull connection"
    }
    catch {
        update-error "Unable to connect with vCenter."
    }

    finally {
        Disconnect-VIServer -Server $VIServer -Confirm:$false -ErrorAction SilentlyContinue
        Exit-Json $module
    }
}

if ($vcenter_action -eq "cert_validation" -and -not ($ca_cert_path -or $machine_ssl_cert_path)){
    update-error "Unable to find required certificate file(s)"
}
try {

    $VIServer = Connect-VIServer -Server $vcenter_server -User $vcenter_user -Password $vcenter_password -ErrorAction Stop 


    if ($vcenter_action -eq "add_CA") {
        $module.msg += "Trying to add CA root certificate \n"
        $trustedCertChain = Get-Content $ca_cert_path -Raw
        Add-VITrustedCertificate -PemCertificateOrChain $trustedCertChain -VCenterOnly -Confirm:$false
        $module.msg += "CA added to vCenter trusted store."
        $module.changed = $true
        $module.status = "Success"
        Exit-Json $module
    }

    elseif ($vcenter_action -eq "replace_certificate") {
        $module.msg += "Trying to replace SSL certificate \n"
        $vcCert = Get-Content $machine_ssl_cert_path -Raw
        Set-VIMachineCertificate -PemCertificate $vcCert -Confirm:$false
        $module.msg += "Machine SSL certificate replaced successfully. "
        $module.changed = $true
        $module.status = "Success"
        Exit-Json $module
    }

    else {
        update-error "Error 2002: unsupported vcenter_action"
    }

}
catch {
    update-error "Error 2003, General PowerCLI/PowerShell error during certificate operation"
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

if (-not $module.msg -or $module.msg.Trim() -eq "") {
    if ($module.failed) {
        $module.msg = "An error occurred, but no specific error message was provided."
    } elseif ($module.changed) {
        $module.msg = "The operation completed successfully and changes were made."
    } else {
        $module.msg = "The operation completed successfully with no changes."
    }
}

if ($module.failed) {
    $module.msg = "vCenter Certificate Management FAILED. " + $module.msg
} elseif ($module.changed) {
    $module.msg = "vCenter Certificate Management SUCCEEDED with changes. " + $module.msg
} else {
    $module.msg = "vCenter Certificate Management SUCCEEDED (read-only or no change). " + $module.msg
}

Exit-Json $module
