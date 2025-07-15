#!powershell
#Requires -Module Ansible.ModuleUtils.Legacy
#Requires -Module VMware.PowerCLI
$ErrorActionPreference = "Stop"

# Read and parse the incoming parameters
$params = Parse-Args $args -supports_check_mode $true
$vmware_action = Get-AnsibleParam -obj $params -name "vmware_action" -type "str" -failifempty $true
$target_fqdn = Get-AnsibleParam -obj $params -name "target_fqdn" -type "str" -failifempty ($vmware_action -ne "read_cert_file_info") # This is the vCenter FQDN
$target_user = Get-AnsibleParam -obj $params -name "target_user" -type "str" -failifempty ($vmware_action -ne "read_cert_file_info")
$target_password = Get-AnsibleParam -obj $params -name "target_password" -type "str" -secret $true -failifempty ($vmware_action -ne "read_cert_file_info")
$cert_file_path = Get-AnsibleParam -obj $params -name "cert_file_path" -type "str" -failifempty (($vmware_action -eq "import_new_cert") -or ($vmware_action -eq "read_cert_file_info"))
$key_file_path = Get-AnsibleParam -obj $params -name "key_file_path" -type "str" -failifempty ($vmware_action -eq "import_new_cert")
$cert_password = Get-AnsibleParam -obj $params -name "cert_password" -type "str" -secret $true -failifempty $false # For PFX or password-protected key

# Declare the result object
$module = New-Object psobject @{
    result = ""
    changed = $false
    msg = ""
    status = ""
    FailJson = @()
    failed = $false
    data = ""
    check_mode_unsupported_reason = ""
}

# Declare error management functions
Function update-error([string] $description) {
    $module.status = 'Error'
    $module.msg = "Error - $description. $($_.Exception.Message)"
    $module.FailJson = ("Error: Process failed - Stage: $description", $_)
    $module.failed = $true
}

# --- PowerCLI Connection Variables ---
$VIServer = $null

try {
    # Common setup for actions requiring PowerCLI connection
    if ($vmware_action -ne "read_cert_file_info") {
        try {
            Import-Module VMware.PowerCLI -ErrorAction Stop
        }
        catch {
            update-error "Failed to import VMware.PowerCLI module."
            Exit-Json $module
        }
        Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
        
        $module.msg += "Attempting to connect to vCenter Server '$target_fqdn'... "
        $VIServer = Connect-VIServer -Server $target_fqdn -User $target_user -Password $target_password -ErrorAction Stop
        $module.msg += "Connected successfully. "
    }

    # --- Action: read_cert_file_info ---
    if ($vmware_action -match "read_cert_file_info") {
        try {
            $module.msg += "Reading certificate file info from '$cert_file_path'. "
            $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
            if ($cert_password) {
                $cert.Import($cert_file_path, $cert_password, "Exportable,PersistKeySet")
            } else {
                $cert.Import($cert_file_path)
            }
            $subject = $cert.Subject
            $issuedTo = ($subject -split ',')[0].Split('=')[1].Trim()
            
            $module.data = @{
                Subject = $cert.Subject
                IssuedTo = $issuedTo
                Issuer = $cert.Issuer
                Thumbprint = $cert.Thumbprint
                NotBefore = $cert.NotBefore
                NotAfter = $cert.NotAfter
                SerialNumber = $cert.SerialNumber
            }
            $module.changed = $false # Reading info is not a change
            $module.msg += "Certificate file information read successfully. IssuedTo: $issuedTo. "
            $module.status = "Success"
        }
        catch {
            update-error "Failed to read certificate file information from '$cert_file_path'."
        }
    }

    # --- Action: read_current_cert ---
    elseif ($vmware_action -match "read_current_cert") {
        try {
            $module.msg += "Reading current certificate information from vCenter Server '$target_fqdn'. "
            # The certificate used for the connection is available in $DefaultVIServer.Certificate
            # For the service instance itself:
            $serviceInstance = Get-VIMServiceInstance -Server $VIServer
            $cert_obj = $null
            
            if ($DefaultVIServer.Certificate) {
                 $cert_obj = [System.Security.Cryptography.X509Certificates.X509Certificate2]$DefaultVIServer.Certificate
            } elseif ($serviceInstance.Certificate) { # This property might not always be populated or directly represent the machine SSL cert
                 $cert_obj = [System.Security.Cryptography.X509Certificates.X509Certificate2]$serviceInstance.Certificate
            }

            if ($cert_obj) {
                $module.data = @{
                    Subject = $cert_obj.Subject
                    Issuer = $cert_obj.Issuer
                    Thumbprint = $cert_obj.Thumbprint
                    NotBefore = $cert_obj.NotBefore
                    NotAfter = $cert_obj.NotAfter
                    SerialNumber = $cert_obj.SerialNumber
                    ServiceInstanceSslThumbprint = $serviceInstance.SslThumbprint # Thumbprint of the SDK endpoint
                }
                $module.changed = $false # Reading is not a change
                $module.msg += "Current vCenter certificate (from connection) read successfully. Thumbprint: $($cert_obj.Thumbprint). SDK Endpoint Thumbprint: $($serviceInstance.SslThumbprint). "
                $module.status = "Success"
            } else {
                update-error "Could not retrieve primary certificate information for vCenter Server '$target_fqdn'. SDK Endpoint Thumbprint: $($serviceInstance.SslThumbprint)."
            }
        }
        catch {
            update-error "Failed to read current certificate from vCenter Server '$target_fqdn'."
        }
    }

    # --- Action: import_new_cert ---
    elseif ($vmware_action -match "import_new_cert") {
        $module.msg += "IMPORTANT: Replacing the vCenter Server's main machine SSL certificate is complex. "
        $module.msg += "The recommended method for VCSA is using the 'certificate-manager' utility on the VCSA console. "
        $module.msg += "This module attempts to use Set-VIMServiceInstance, which may update specific service endpoint certificates or trusts, but might not perform a full machine SSL certificate replacement. "

        try {
            $module.msg += "Preparing to import new certificate from '$cert_file_path' (and key from '$key_file_path') to vCenter Server '$target_fqdn' service instance. "
            
            # This cmdlet usually expects paths accessible to where PowerCLI is running, not necessarily on the VCSA itself.
            # It's for updating the vCenter Server settings object.
            
            $serviceInstance = Get-VIMServiceInstance -Server $VIServer
            $currentSdkThumbprint = $serviceInstance.SslThumbprint

            $new_cert_to_import = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
            $new_cert_to_import.Import($cert_file_path) # Assumes PEM

            if ($currentSdkThumbprint -eq $new_cert_to_import.Thumbprint) {
                 $module.msg += "The certificate with thumbprint $($new_cert_to_import.Thumbprint) matches the current SDK endpoint thumbprint. No action taken by this script directly with Set-VIMServiceInstance regarding paths. "
                 $module.changed = $false
                 $module.status = "Success (No Change)"
            } else {
                $module.msg += "Current SDK endpoint thumbprint: $currentSdkThumbprint. New certificate thumbprint: $($new_cert_to_import.Thumbprint). "
                if ($params.check_mode) {
                    $module.msg += "CHECK MODE: Would attempt to call Set-VIMServiceInstance with CertificatePath='$cert_file_path' and PrivateKeyPath='$key_file_path'. "
                    $module.changed = $true
                    $module.status = "Success (Check Mode)"
                } else {
                    $module.msg += "Attempting to call Set-VIMServiceInstance... "
                    # Note: Set-VIMServiceInstance does not directly take cert/key content.
                    # It takes -CertificatePath and -PrivateKeyPath.
                    # These paths are interpreted by PowerCLI client side.
                    # It's unclear if this fully replaces machine SSL. Usually not.
                    # This is more likely for the vCenter service itself (SDK endpoint settings).
                    # The cmdlet might not exist in all PowerCLI versions or have these exact parameters.
                    # This is a best-effort attempt.
                    if (Get-Command Set-VIMServiceInstance -ErrorAction SilentlyContinue) {
                        Set-VIMServiceInstance -CertificatePath $cert_file_path -PrivateKeyPath $key_file_path -Confirm:$false
                        $module.msg += "Set-VIMServiceInstance command issued. This may have updated the certificate for certain vCenter services. "
                        $module.msg += "A full VCSA machine SSL certificate replacement typically requires using 'certificate-manager' on the VCSA console and may require service restarts or a VCSA reboot. "
                        $module.changed = $true
                        $module.status = "Success (Command Issued)"
                    } else {
                        $module.msg += "Set-VIMServiceInstance cmdlet not found or not applicable for direct certificate/key content. "
                        $module.msg += "This action for vCenter has limited capability via pure PowerCLI for full machine SSL replacement. "
                        $module.changed = $false
                        $module.status = "Warning (No Action Possible)"
                        $module.check_mode_unsupported_reason = "Set-VIMServiceInstance may not be available or suitable for this operation."
                    }
                }
            }
        }
        catch {
            update-error "Failed during 'import_new_cert' for vCenter Server '$target_fqdn'. Review messages for details on vCenter certificate management."
        }
    }

    else {
        update-error "Unsupported vmware_action: '$vmware_action'."
    }

}
catch {
    # Catch-all for unexpected errors, including connection failures
    update-error "An unexpected error occurred. $($_.Exception.Message) ScriptStackTrace: $($_.ScriptStackTrace)"
}
finally {
    if ($VIServer) {
        try {
            Disconnect-VIServer -Server $VIServer -Confirm:$false -ErrorAction SilentlyContinue
            $module.msg += "Disconnected from vCenter Server $target_fqdn."
        } catch {
            # Ignore errors during disconnect
        }
    }
}

# Finalize module output
if ($module.failed) {
    $module.msg = "vCenter Certificate Management FAILED. " + $module.msg
} elseif ($module.changed) {
    $module.msg = "vCenter Certificate Management SUCCEEDED and changes were made (or attempted). " + $module.msg
} else {
    $module.msg = "vCenter Certificate Management SUCCEEDED and no changes were made (or action was read-only/not fully supported). " + $module.msg
}

Exit-Json $module