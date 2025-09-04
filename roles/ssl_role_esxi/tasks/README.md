# README 

## Synopsis

This Ansible role is designed to automate the replacement of SSL certificates on a VMWare ESXi host. It performs the following high-level actions via custom PowerShell module "esxi_cert_mgmt":

1. Sets vCenter certificate management mode to 'custom'
2. Places the ESXi host in 'Maintenance mode', powering off running VMs and recording their names.
3. Detaches the ESXi host from any vDS (if present) and remove it from vCenter, while capturing its Datacenter and Cluster location. 
4. Replaces the ESXi Machine SSL certificate and reboot the host.
5. Re-adds the host to the original vCenter location.
6. Power on the VMs that were shut down in step 2.

## Known limitations

- Certificate Sign Request limitation

It is important to highlight that this automation requires the SSL certificate to originate from a very specific workflow. The Certificate Signing Request (CSR) must be generated directly from vCenter, either through the vCenter UI or via PowerCLI commands (e.g., `New-VIMachineCertificateSigningRequest`). This step is critical because it ensures the corresponding private key is created and stored locally on the host. The automation script installs the public certificate and relies on the host already possessing the matching private key. Furthermore, when having the CSR signed by a Certificate Authority (CA), it is vital to use a valid Certificate Template, this ensures the certificate is issued with the required Extended Key Usages (EKU), such as "Server Authentication" and "Client Authentication", for full compatibility. Using a certificate generated externally (where the private key does not reside on the host) will cause the replacement step to fail.

Example: Generating a CSR using PowerCLI

The following PowerCLI script demonstrates how to generate a CSR for a specific ESXi host managed by a vCenter Server.

To comply with the automation's requirements, the Certificate Signing Request (CSR) must be generated from the ESXi host itself. This ensures the private key is created and stored on the host, which is essential for the certificate replacement process.

The following PowerCLI script demonstrates how to generate a CSR for a specific ESXi host managed by a vCenter Server.

* Procedure

Step 1: Connect to your vCenter Server
Open a PowerShell terminal with the VMware PowerCLI module loaded and connect to the vCenter Server that manages your ESXi host.

Connect-VIServer -Server 'vcenter01.local.com' -User 'administrator@vsphere.local' -Password 'YourPassword'

Step 2: Define the Certificate Details 

Create a hashtable with the information for your certificate. The CommonName is the most critical field and must match the Fully Qualified Domain Name (FQDN) of your ESXi host.

Get the ESXi host object from vCenter

$targetHost = Get-VMHost -Name 'esx01.yourdomain.com'

Define all the subject details for the certificate

$esxRequest = New-VIMachineCertificateSigningRequest `
    -VMHost $vmhost `
    -Country "US" `
    -Locality "San Francisco" `
    -Organization "My Company" `
    -OrganizationUnit "PowerCLI" `
    -StateOrProvince "California" `
    -CommonName "esx01.yourdomain.com"

Step 3: Save the CSR to a File
The generated CSR is a block of Base64-encoded text. Save it to a .pem or .csr file. This is the file you will submit to your Certificate Authority (CA) for signing.

$esxRequest.CertificateRequestPEM | Out-File "C:Users\certs\esx01.csr.pem" -Force



After completing these steps, you will have the esx01.csr.pem file ready to be signed. Once your CA returns the signed certificate, ensure it includes the full chain of trust and use that file as the input for the esxi_cert_path variable in the Ansible role.


- vSphere Distributed Switches

It is important to consider that the host's management network, including its primary VMkernel adapter, must be configured on a vSphere Standard Switch. This automation won't be able to remove the ESXi host from vCenter if the management network is on a vSphere Distributed Switch (VDS), as it does not handle the VDS migration. Attempting to run this on a VDS-managed host will require manual intervention.


## Variables 

This section describes all variables that can be used with this Ansible role. Each variable is listed below with its name, type, default value and a description of its purpose. 

Variable | Default | Comments
---------|---------|---------
*vcenter_server* (String) | None | Hostname of the vCenter server, e.g., vcenter01.local.com
*vcenter_user* (String) | None | vCenter user with admin privileges, e.g., administrator@vsphere.local
*vcenter_password* (String) | None | Password for the vCenter user
*esxi_host* (String) | None | ESXi host FQDN to operate on
*esxi_user* (String) | None | ESXi local user with required privileges
*esxi_password* (String) | None | Password for the ESXi host
*esxi_cert_path* (String) | None | Path to the desired new certificate (PEM format), e.g., C:\path\to\ca_root.pem
*target_datacenter* (String) | Set at runtime | Datacenter name used to re-add the host (captured during removal)
*target_cluster* (String) |Set at runtime | Cluster name used to re-add the host (captured during removal)
*vms_to_power_on* (Array) | Set at runtime | Names of VMs powered off during the maintenance step, to be started after re-add.



Note: All file paths must be absolute and accessible by the Ansible controller. Certificate files must be in CER or PEM format or (base64-encoded).


## Results from execution

After the execution, the playbook will log a return code for each node to identify the result. Use this as a reference.

Return Code Group | Return Code | Comments
------------------|-------------|---------
custom_mode | 1000 | Failed to set vCenter custom mode
maintenance_mode | 2000 | Failed to enter maintenance mode.
remove_host | 3000 | Filed to remove host from vCenter.
replace_cert | 4000 | Failed to replace ESXi Machine certificate.
wait_for_esxi_api | 4100 | Timeout waiting for ESXi HTTPS (443) to become available.
re-add_host | 5000 | Failed to re-add ESXi host vCenter.
power_on_vms | 5100 | Failed to power on all VMs.
generic | 9000 | Unexpected/uncategorized failure.


## Procedure 

This automation performs the following steps to manage SSL certificates on a ESXi Host: 

1. Set vCenter custom mode
Calls esxi_cert_mgmt with esxi_action: custom_mode to set vpxd.certmgmt.mode=custom.

2. Enter Maintenance Mode & stop VMs
Calls esxi_cert_mgmt with esxi_action: maintenance.

- Powers off any VMs running on the target host.

- Waits for them to stop.

- Puts the host into Maintenance Mode.

- Returns data.PoweredOffVMs.

3. Remove host from vCenter
Calls esxi_cert_mgmt with esxi_action: remove.

- Detaches from vDS if present.

- Captures Datacenter and Cluster into data.HostLocation.

- Removes the host from vCenter.

4. Replace ESXi Machine SSL certificate
Calls esxi_cert_mgmt with esxi_action: replace_cert.

- Connects directly to ESXi.

- Applies the PEM using Set-VIMachineCertificate.

- Reboots the host.

5. Re-add host to vCenter
Calls esxi_cert_mgmt with esxi_action: re-add.

- Re-adds to the original Cluster when available; otherwise, to the Datacenter Host Folder.

- Ensures the host is Connected.

6. Power on VMs
Calls esxi_cert_mgmt with esxi_action: turn_on_vms to start the VMs recorded in step 2.

Each major block includes a rescue path to surface a clear failure message.

* Notes: 
Sensitive Variables:
The variables vcenter_password and certificate file paths must be provided securely and must point to files accessible by the Ansible controller.

Variable Values:

All paths should be absolute and use escaped backslashes if running on Windows (C:\\Users\\user\\Desktop\\cert.cer).

## Rollback behavior

- Maintenance: If the host is already in Maintenance Mode, the module reports NoChange. On failure, it attempts to exit Maintenance and power on any VMs it stopped.

- Removal: On failure before the host is actually removed, the module attempts to exit Maintenance and power on VMs (if provided).

- Replace certificate: If the error occurs before the certificate is applied, the module attempts to re-add the host (if missing), exit Maintenance, and power on VMs. On the other hand, if the certificate was applied and the host rebooted, the module flags the situation for manual verification.

- Re-add: If the host already exists in vCenter, the module ensures it is Connected and returns NoChange.

- Power on VMs: Starts only VMs that are currently PoweredOff; skips missing or already powered-on VMs.

## Support

Information how to submit issue, what is a governance, who are main contacts, what is email task ID or Community/Channel for communication, ...
If some information are common for more assets at once - maintain them centrally and put a link here.

List information required to contact the development team which supports the asset, including a **support contact** and a **support URL** which are described in the [CE Asset Tagging Document](https://github.kyndryl.net/Continuous-Engineering/CE-Documentation/blob/master/Asset%20Lifecycle%20Management/Asset_Tagging.md#development-team).

Generally see [12 factors to measuring an open source project's health](https://www.redhat.com/en/blog/12-factors-measuring-open-source-projects-health) following sections from the document should be reflected in this chapter:

* Project life cycle
* Governance
* Project leads
* Goals and roadmap
* Onboarding processes
* Outreach

## Deployment

* In the case of Ansible Collection - detailed description how the asset should be deployed into "framework":
  * How to configure Ansible Tower Project and Job Template. Instructions **must be in accordance of [CACF Ansible Tower Object Naming Standards](https://github.kyndryl.net/Continuous-Engineering/TWPs/tree/master/CACF%20Ansible%20Tower%20Object%20Naming%20Standards)!**
  * The Ansible Tower Project "SCM Branch/Tag/Commit" field must specify a specific asset version (for example, 1.0.0).
  * Ansible Tower Job Template instructions are required to include a recommended job frequency (for example, monthly), unless the Tower Job Template instructions identify the automation as strictly executed on demand.
* Which Ansible Execution Environment must be used.
* In the case of Ansible Role which is plugable to specific Ansible Framework - this chapter must contain link to General Deployment Instructions for given Framework. For example:
  * [Deployment Instructions for CACF Event Automation](https://community-engineering.kyndryl.net/markdown/Continuous-Engineering%2FCACM_Automation_Services%2Fblob%2Fmaster%2Fhowto-deploy-new-ansible-automation.md)
  * [Deployment Instructions for CACF Service Request Automation](https://github.kyndryl.net/Continuous-Engineering/CE-Documentation/tree/master/Community%20Guidelines/Ansible%20Guides/SRA%20Guides)
* In the case of Ansible Role which is intended for specific Ansible Collection only, this chapter must contain link to this Collection.
* In the case of Ansible Role is Generic Reusable "component" and can be used in whatever another Ansible Collections - this chapter must contain reference to chapter Examples where must be commented pieces of code which demonstrate how to incorporate Ansible Role to another solution. Typical examples of Generic Reusable "component" are [Building Blocks](https://github.kyndryl.net/Continuous-Engineering/CE-Documentation/blob/master/Community%20Guidelines/Ansible%20Guides/Development%20Standards/BuildingBlocks.md).

## Known problems and limitations

* Description of all limitations and known problems.
  * Which platforms are or are not supported.
* ...

## Prerequisites

* Description of environment and prerequisites which are needed for correct functionality of the Ansible Role.
* Which [Execution Environment](./General_Development_Rules.md#dependencies-to-kyndrylcustomer-ansible-tower-environment) must be used for deployment.
