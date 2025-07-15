#!powershell
#Requires -Module Ansible.ModuleUtils.Legacy
#Requires -Module VMware.PowerCLI
$ErrorActionPreference = "Stop"

# Read and parse the incoming parameters
$params = Parse-Args $args -supports_check_mode $true
$vmware_action = Get-AnsibleParam -obj $params -name "vmware_action" -type "str" -failifempty $true
$target_fqdn = Get-AnsibleParam -obj $params -name "target_fqdn" -type "str" -failifempty ($vmware_action -ne "read_cert_file_info")
$target_user = Get-AnsibleParam -obj $params -name "target_user" -type "str" -failifempty ($vmware_action -ne "read_cert_file_info")
$target_password = Get-AnsibleParam -obj $params -name "target_password" -type "str" -secret $true -failifempty ($vmware_action -ne "read_cert_file_info")
$cert_file_path = Get-AnsibleParam -obj $params -name "cert_file_path" -type "str" -failifempty (($vmware_action -eq "import_new_cert") -or ($vmware_action -eq "read_cert_file_info"))
$key_file_path = Get-AnsibleParam -obj $params -name "key_file_path" -type "str" -failifempty ($vmware_action -eq "import_new_cert")
$cert_password = Get-AnsibleParam -obj $params -name "cert_password" -type "str" -secret $true -failifempty $false # For PFX or password-protected key
$vcenter_fqdn = Get-AnsibleParam -obj $params -name "vcenter_fqdn" -type "str" -failifempty $false # Optional: if managing ESXi via vCenter

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
$VIServerConnection = $null # Renamed for clarity

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
        
        $connection_target_server = if ($vcenter_fqdn) { $vcenter_fqdn } else { $target_fqdn }
        $module.msg += "Attempting to connect to $connection_target_server... "
        $VIServerConnection = Connect-VIServer -Server $connection_target_server -User $target_user -Password $target_password -ErrorAction Stop
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
            $module.msg += "Reading current certificate from ESXi host '$target_fqdn'. "
            $vmhost = Get-VMHost -Name $target_fqdn -Server $VIServerConnection -ErrorAction Stop
            
            # Access the certificate via ExtensionData
            $certManager = $vmhost.ExtensionData.Config.CertificateManager
            if ($certManager -and $certManager.CertificateInfo -and $certManager.CertificateInfo.Certificate) {
                # CertificateInfo.Certificate is an array, usually the first one is the active SSL cert
                $pemCertificateString = $certManager.CertificateInfo.Certificate[0]
                
                # Convert PEM string to X509Certificate2 object
                $certBytes = [System.Text.Encoding]::UTF8.GetBytes($pemCertificateString)
                $current_cert_obj = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
                $current_cert_obj.Import($certBytes)

                $module.data = @{
                    Subject = $current_cert_obj.Subject
                    Issuer = $current_cert_obj.Issuer
                    Thumbprint = $current_cert_obj.Thumbprint
                    NotBefore = $current_cert_obj.NotBefore
                    NotAfter = $current_cert_obj.NotAfter
                    SerialNumber = $current_cert_obj.SerialNumber
                    RawCertificate = $pemCertificateString # PEM Encoded
                }
                $module.changed = $false # Reading is not a change
                $module.msg += "Current ESXi certificate read successfully. Thumbprint: $($current_cert_obj.Thumbprint). "
                $module.status = "Success"
            } else {
                update-error "Could not retrieve certificate information for ESXi host '$target_fqdn' via CertificateManager."
            }
        }
        catch {
            update-error "Failed to read current certificate from ESXi host '$target_fqdn'."
        }
    }

    # --- Action: import_new_cert ---
    elseif ($vmware_action -match "import_new_cert") {
        try {
            $module.msg += "Preparing to import new certificate from '$cert_file_path' and key from '$key_file_path' to ESXi host '$target_fqdn'. "
            
            $cert_content = Get-Content -Path $cert_file_path -Raw
            $key_content = Get-Content -Path $key_file_path -Raw

            $vmhost = Get-VMHost -Name $target_fqdn -Server $VIServerConnection -ErrorAction Stop
            
            # Get current certificate for comparison
            $current_cert_obj = $null
            $certManager = $vmhost.ExtensionData.Config.CertificateManager
            if ($certManager -and $certManager.CertificateInfo -and $certManager.CertificateInfo.Certificate) {
                $pemCertificateString = $certManager.CertificateInfo.Certificate[0]
                $certBytes = [System.Text.Encoding]::UTF8.GetBytes($pemCertificateString)
                $current_cert_obj = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
                $current_cert_obj.Import($certBytes)
            } else {
                $module.msg += "Warning: Could not retrieve current ESXi certificate for comparison. Proceeding with import. "
            }

            $new_cert_to_import_obj = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
            # Assuming $cert_content is PEM, $new_cert_to_import_obj.Import($cert_content) might not work directly if it's just content
            # $new_cert_to_import_obj.Import([System.Text.Encoding]::UTF8.GetBytes($cert_content)) or $new_cert_to_import_obj.Import($cert_file_path)
            $new_cert_to_import_obj.Import($cert_file_path) # Easiest to import from file for thumbprint

            if ($current_cert_obj -and ($current_cert_obj.Thumbprint -eq $new_cert_to_import_obj.Thumbprint)) {
                $module.msg += "The certificate with thumbprint $($new_cert_to_import_obj.Thumbprint) is already installed. No action needed. "
                $module.changed = $false
                $module.status = "Success"
            } else {
                if ($current_cert_obj) {
                    $module.msg += "Current certificate thumbprint: $($current_cert_obj.Thumbprint). New certificate thumbprint: $($new_cert_to_import_obj.Thumbprint). Change required. "
                } else {
                     $module.msg += "New certificate thumbprint: $($new_cert_to_import_obj.Thumbprint). Proceeding with import as current cert could not be read. "
                }

                if ($params.check_mode) {
                    $module.msg += "CHECK MODE: Would import new certificate. "
                    $module.changed = $true
                    $module.status = "Success (Check Mode)"
                } else {
                    $module.msg += "Attempting to set new certificate... "
                    # Set-VIMachineCertificate expects the string content of the PEM certificate and private key
                    Set-VIMachineCertificate -VMHost $vmhost -Certificate $cert_content -PrivateKey $key_content -Confirm:$false # Removed -RunAsync for simplicity, can add back if needed
                    # Note: Applying a new certificate often puts the host into maintenance mode and may reboot it.
                    # This is a disruptive operation.
                    $module.msg += "Set-VIMachineCertificate command issued. ESXi host will apply the certificate. This may involve the host entering maintenance mode and/or rebooting. "
                    $module.changed = $true
                    $module.status = "Success"
                }
            }
        }
        catch {
            update-error "Failed to import new certificate to ESXi host '$target_fqdn'."
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
    if ($VIServerConnection) {
        try {
            $server_to_disconnect = $VIServerConnection.Name
            Disconnect-VIServer -Server $VIServerConnection -Confirm:$false -ErrorAction SilentlyContinue
            $module.msg += "Disconnected from $server_to_disconnect."
        } catch {
            # Ignore errors during disconnect
        }
    }
}

# Finalize module output
if ($module.failed) {
    $module.msg = "ESXi Certificate Management FAILED. " + $module.msg
} elseif ($module.changed) {
    $module.msg = "ESXi Certificate Management SUCCEEDED and changes were made. " + $module.msg
} else {
    $module.msg = "ESXi Certificate Management SUCCEEDED and no changes were made (or action was read-only). " + $module.msg
}

Exit-Json $module