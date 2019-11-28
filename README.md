# Azure Linux CLI helpers

Helper shell functions for Azure resource management.

## Index

- [Installation](#installation)
- [Reference](#reference)

### Installation

1. Clone this repository.

2. Set the following environment variables (most likely in your `~/.bashrc`):

```
export AZLH_PREFIX="..."  # e.g. thstring
export AZLH_ADMIN_USERNAME="..."  # e.g. trstringer
export AZLH_REGION="..."  # e.g. eastus
export AZLH_DEFAULT_IMAGE_NAME="Canonical:UbuntuServer:18.04-LTS:latest"
export AZLH_PROXY_SERVER_PRIVATE_IP="..."
export AZLH_SSH_KEY_FILE="..."
```

3. Add the following to `~/.bashrc`:

```
# Import Azure CLI helpers.
CLI_HELPERS_SCRIPT="/home/trstringer/dev/azure/cli_helpers.sh"
if [[ -f "$CLI_HELPERS_SCRIPT"  ]]; then
    source "$CLI_HELPERS_SCRIPT"
fi
```

Note: Change `$CLI_HELPERS_SCRIPT` to the correct location of the script on your machine.

### Reference

If you are unsure of the parameters for a helper function, pass no parameters and it should show the available parameters.

#### Resource group helpers

* **az_group_create** - Create a resource group (unlikely that it'll be needed directly).
* **az_group_list** - List all resource groups and info.
* **az_group_delete** - Delete a specific resource group.
* **az_group_delete_all** - Delete all resource groups that have a prefix of `$AZLH_PREFIX`.

#### VM helpers

* **az_vm_create** - Create a VM with a specific image (could be PIR or custom image) and optionally custom data.
* **az_vm_create_default** - Create a VM with the default image.
* **az_vm_image_list_sku_ubuntu** - List all Ubuntu skus.
* **az_vm_image_list_version_ubuntu** - List all Ubuntu versions for a particular sku.
* **az_vm_ovf_dump** - Dump the OVF file from a VM.
* **az_vm_ssh** - SSH to an Azure Linux VM through a proxy server.
* **az_vm_scp_out** - Secure copy a file to an Azure Linux VM through a proxy server.
* **az_vm_deb_install** - Install a local deb on a remote Azure Linux VM through a proxy server.
* **az_vm_rpm_install** - Install a local rpm on a remote Azure Linux VM through a proxy server.
* **az_vm_rpm_update** - Force update a local rpm on a remote Azure Linux VM through a proxy server.

#### Storage helpers

* **az_storage_account_create** - Create a storage account (unlikely that it'll be needed directly).


#### Network helpers

* **az_network_public_ip_list** - List all public IP addresses that start with `$AZLH_PREFIX`.

#### Image helpers

* **az_image_list** - List all images that start with `$AZLH_PREFIX`.
* **az_image_create_from_vm** - Create a managed image from an Azure Linux VM.
