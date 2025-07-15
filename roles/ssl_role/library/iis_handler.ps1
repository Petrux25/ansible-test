#!powershell
#Requires -Module Ansible.ModuleUtils.Legacy
$ErrorActionPreference = "Stop"

# Read and parse the incoming parameters
$params = Parse-Args $args -supports_check_mode $true
$action = Get-AnsibleParam -obj $params -name "iis_action" -type "str" -failifempty $true
$site_name = Get-AnsibleParam -obj $params -name "site_name" -type "str" -failifempty $false
$cert_id = Get-AnsibleParam -obj $params -name "cert_id" -type "str" -failifempty $false
$cert_name = Get-AnsibleParam -obj $params -name "cert_name" -type "str" -failifempty $false
$cert_key = Get-AnsibleParam -obj $params -name "cert_key" -type "str" -failifempty $false

# Declare the result object to share all details later

$module = New-Object psobject @{
    result = ""
    changed = $false
    msg = ""
    status = ""
    FailJson = @()
    failed = $false
    data = ""
    site_data_json = @()
  }

# Declare error management functions

Function update-error([string] $description)
{
    $module.status = 'Error'
    $module.details = "Error - $description"
    $module.FailJson = ("Error: Failover management process failed - Stage: $description", $_)
    $module.failed = $true
}



# ---------- Main ----------
# We will first test if all resources are online, if not, we will try to bring them up

try {
    Import-Module WebAdministration
}
catch {
    $changed = $false
    update-error "Failed to import web management PS module."
}

if ($action -match "read_cert"){

    try {
        # Get the certificate information
        $cert_key | out-file -filepath c:\temp\test.txt -Append
        $cert_name | out-file -filepath c:\temp\test.txt -Append
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
        $cert.Import("$cert_name", $cert_key, "Exportable,PersistKeySet")
        $subject = $cert.Subject

        # Extract the CN from the subject
        $issuedTo = ($subject -split ',')[0].Split('=')[1].Trim() | Out-String
        $issuedTo = $issuedTo.TrimEnd("`r`n")
        $module.data = $issuedTo
        $changed = $true
        $module.msg += 'Certificate information ok'

    }
    catch {
        $changed = $false
        update-error "Failed to read certificate information."
    }


}

if ($action -match "complete"){

    try {
        $cert = Import-Certificate -FilePath $cert_name -CertStoreLocation Cert:\LocalMachine\My
        certutil -repairstore my $cert.Thumbprint
        $cert.FriendlyName = $site_name
    }
    catch {
        $changed = $false
        update-error "Failed to complete certificate request (generate private key)"
    }
}

if ($action -match "import"){

try {

                  # Get the web binding of the site and configure the binding
                  $binding = Get-WebBinding -Name $site_name -Protocol "https"; $binding.AddSslCertificate($cert_id, "my")


    $changed = $true
    $module.msg += 'Certificate succesfully imported'
}
catch {
    $changed = $false
    update-error "Failed to import certificate into the site."
}

}

if ($action -match "read_sites"){

try {
    
    
    Get-WebBinding | Where-Object {$_.protocol -eq 'https'} | ForEach-Object {
    $site = $_.ItemXPath -replace '(?:.*?)name=''([^'']*)(?:.*)', '$1'
    $bindingInfo = $_.bindingInformation
    $binding = $_.bindingInformation -replace '(?:.*):([^:]*)(?:.*)', '$1'
    $port = ($bindingInfo -split ':')[1]  # Extract the port

    # Create a custom object with Site, Binding, and Port properties
    $module.site_data_json += [PSCustomObject]@{
    Site = $site
    Binding = $binding
    Port = $port
    }
    } 
}
catch {
    $changed = $false
    update-error "Failed to read IIS sites."
}


}

# Did the configuration change?
if ($changed -eq $true) {
    # Set the the changed flag
    $module.changed = $true

    # Set the information message
    $module.msg += 'Process completed succesfully.'
} else {
    # Set the the changed flag
    $module.changed = $false

    # Set the information message
    $module.msg += 'Process could not be completed.'
}

# Exit gracefully
Exit-Json $module