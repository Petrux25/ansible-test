#Requires -Module VMware.PowerCLI
#Requires -Module Ansible.ModuleUtils.Legacy

$ErrorActionPreference =  "Stop"

$params = Parse-Args $args -supports_check_mode $true
$vcenter_action = Get-AnsibleParam -obj$params -name "vcenter_action" -type "str" -failifempty $false
$vcenter_server = Get-AnsibleParam -obj $params -name "vcenter_server" -type "str" -failifempty $false
$vcenter_user = Get-AnsibleParam -obj $params -name "vcenter_user" -type "str" -failifempty $false
$vcenter_password = Get-AnsibleParam -obj $params -name "vcenter_password" -type "str" -secret $true -failifempty $false
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
try {
    $module.msg += "Entrando en el try"

    $module.msg += "Probando conectar con vcenter"

    # 1. Conectarse SIEMPRE al principio
    $VIServer = Connect-VIServer -Server $vcenter_server -User $vcenter_user -Password $vcenter_password -ErrorAction Stop 
    $module.msg += "Connected to vCenter. "


    Exit-Json $module
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
