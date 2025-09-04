# README 

## Synopsis

This Ansible role is designed to automate the management of SSL certificates on a VMWare vCenter server. It connects with to the vCenter instance, validates connectivity, installs a specified CA root certificate into the trusted certificate store, and replaces the Machine SSL certificate with a new one provided by the user.

## Known limitations

- Certificate Sign Request limitation

It is important to highlight that this automation requires the SSL certificate to originate from a very specific workflow. The Certificate Signing Request (CSR) must be generated directly from vCenter, either through the vCenter UI or via PowerCLI commands (e.g., `New-VIMachineCertificateSigningRequest`). This step is critical because it ensures the corresponding private key is created and stored locally on the host. The automation script installs the public certificate and relies on the host already possessing the matching private key. Furthermore, when having the CSR signed by a Certificate Authority (CA), it is vital to use a valid Certificate Template, this ensures the certificate is issued with the required Extended Key Usages (EKU), such as "Server Authentication" and "Client Authentication", for full compatibility. Using a certificate generated externally (where the private key does not reside on the host) will cause the replacement step to fail.

Example: Generating a CSR using PowerCLI

The following PowerCLI script demonstrates how to generate a CSR for a vCenter Server Server.

* Procedure

Step 1: Connect to your vCenter Server
Open a PowerShell terminal with the VMware PowerCLI module loaded and connect to the vCenter Server.

Connect-VIServer -Server 'vcenter01.local.com' -User 'administrator@vsphere.local' -Password 'YourPassword'

Step 2: Define the Certificate Details
Create a hashtable with the information for your certificate. 

$csrParams = @{
    Country          = "US"
    Email            = "it-adm@company.com"
    Locality         = "San Francisco"
    Organization     = "My Company"
    OrganizationUnit = "IT Infrastructure"
    StateOrProvince  = "California"
}

Step 3: Generate the CSR

Execute the New-VIMachineCertificateSigningRequest cmdlet with the parameters you defined. This command instructs the ESXi host to generate a new private key and a CSR. The CSR is then returned to your PowerCLI session.

$csr = New-VIMachineCertificateSigningRequest @csrParams

Step 4: Save the CSR to a File
The generated CSR is a block of Base64-encoded text. Save it to a .pem or .csr file. This is the file you will submit to your Certificate Authority (CA) for signing.

$csr.CertificateRequestPEM | Out-File "C:Users\downloads\vcenter.csr.pem" -Force

After completing these steps, you will have the vcenter.csr.pem file ready to be signed. Once your CA returns the signed certificate, ensure it includes the full chain of trust and use that file as the input for the ca_cert_path variable in the Ansible role.

## Variables 

This section describes all variables that can be used with this Ansible role. Each variable is listed below with its name, type, default value and a description of its purpose. 

Variable | Default | Comments
---------|---------|---------
*vcenter_server* (String) | None | Hostname or IP address of the vCenter server, e.g., vcenter01.local.com
*vcenter_user* (String) | None | vCenter user with admin privileges, e.g., administrator@vsphere.local
*vcenter_password* (String) | None | Password for the vCenter user
*ca_cert_path* (String) | None | Path to the CA root certificate (PEM format), e.g., C:\path\to\ca_root.pem
*machine_ssl_cert_path* (String) | None | Path to the Machine SSL certificate (PEM format), e.g., C:\path\to\cert.cer
*vcenter_action* (String) | "add_CA" / "replace_certificate" | Action to perform: "add_CA" to add CA root certificate, "replace_certificate" to replace the Machine SSL certificate


Note: All file paths must be absolute and accessible by the Ansible controller. Certificate files must be in CER or PEM format or (base64-encoded).



## Results from execution

After the execution, the playbook will log a return code for each node to identify the result. Use this as a reference.

Return Code Group | Return Code | Comments
------------------|-------------|---------
prerequisite | 1000 | Host is unreachable (server connectivity failed).
prerequisite | 1001 | vCenter credentials missing or invalid.
prerequisite | 1002 | Required certificate file(s) not found.
vcenter_cert | 2000 | Failed to add CA root certificate to vCenter trust store.
vcenter_cert | 2001 | Failed to replace Machine SSL certificate.
vcenter_cert | 2002 | Unsupported vcenter_action specified.
vcenter_cert | 2003 | General PowerCLI/PowerShell error during certificate operation.


## Procedure 

This automation performs the following steps to manage SSL certificates on a VMware vCenter server: 

1. Displays input variables
Outputs the values of the key variables (ca_cert_path, vcenter_server, vcenter_user, and machine_ssl_cert_path) for debugging and traceability.

2. Validates vCenter Connectivity:
Attempts to connect to the specified vCenter server using the provided credentials. Fails early if unreachable or credentials are invalid.

3. Validates certificate paths.
Verifies the existence of all required certificate files before attempting any changes.

4. Connects to vCenter and adds the CA certificate:
Attempts to connect to the specified vCenter server using the provided credentials and installs the CA root certificate into the vCenter trusted certificate store.

5. Replaces the Machine SSL certificate:
After successfully adding the CA certificate, the playbook initiates the replacement of the Machine SSL certificate in vCenter using the provided certificate file.

* This operation is also wrapped in error handling to report any issues encountered during the process.

6. Handles error:
For each major step (adding CA, replacing certificate), the playbook includes rescue/exception handling. If a task fails, it shows a debug message and fails the playbook for that host with a clear critical error message.

* Notes: 
Sensitive Variables:
The variables vcenter_password and certificate file paths must be provided securely and must point to files accessible by the Ansible controller.

Variable Values:

All paths should be absolute and use escaped backslashes if running on Windows (C:\\Users\\user\\Desktop\\cert.cer).

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
