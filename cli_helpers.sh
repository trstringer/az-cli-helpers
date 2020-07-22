# Azure CLI helper functions
#
# This shell script is meant to be sourced to
# provide helper functions for commonly used
# Azure functionality.

# Function naming convention:
#  az_<resource_type>_<sub_resource_type>_<action>_<specification>

# Configuration settings for helper functions.
# AZLH_PREFIX="..."
# AZLH_ADMIN_USERNAME="..."
# AZLH_REGION="eastus"
# AZLH_DEFAULT_IMAGE_NAME="Canonical:UbuntuServer:18.04-LTS:latest"

# It is recommended to use a non-default SSH key for virtual machines
# created. To create a new SSH key run `ssh-keygen` and then in SSH
# config (~/.ssh/config) specify the host entry to use this identify
# file.
#
# Example entry in ~/.ssh/config:
#
# Host *.cloudapp.azure.com
#  IdentityFile ~/.ssh/id_rsa_az_vm
# AZLH_SSH_KEY_FILE="~/.ssh/id_rsa_az_vm.pub"

SCRIPT_PATH="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

current_date_for_naming () {
    date '+%Y%m%d%H%M%S'
}

full_dns_name () {
    if [[ -z "$1" ]]; then
        echo "You must specify the VM name to generate the fqdn for"
        return
    fi

    local VM_NAME="$1"

    printf "${VM_NAME}.${AZLH_REGION}.cloudapp.azure.com"
}

resource_name () {
    printf "${AZLH_PREFIX}$(current_date_for_naming)"
}

print_usage () {
    local PARAM_NUM=1
    for PARAM in "$@"; do
        echo "Param$PARAM_NUM: $PARAM"
        local PARAM_NUM=$(( $PARAM_NUM + 1 ))
    done
}

##################################################
# Proxy helpers.                                 #
##################################################
az_proxy_setup () {
    if [[ -z "$AZLH_PROXY_VM_NAME" ]]; then
        echo "You must set AZLH_PROXY_VM_NAME"
        return
    fi

    az network nsg create \
        --name "$AZLH_PROXY_VM_NAME" \
        --resource-group "$AZLH_PROXY_VM_NAME"
    az network nsg rule create \
        --name "$AZLH_PROXY_VM_NAME" \
        --nsg-name "$AZLH_PROXY_VM_NAME" \
        --priority 100 \
        --resource-group "$AZLH_PROXY_VM_NAME" \
        --access Allow --direction Inbound \
        --source-address-prefixes $(curl ipinfo.io/ip) \
        --destination-port-ranges 22
    az network vnet subnet update \
        --name "${AZLH_PROXY_VM_NAME}subnet" \
        --vnet-name "${AZLH_PROXY_VM_NAME}vnet" \
        --resource-group "$AZLH_PROXY_VM_NAME" \
        --network-security-group $(az network nsg show \
            --resource-group "$AZLH_PROXY_VM_NAME" \
            --name "$AZLH_PROXY_VM_NAME" --query id -o tsv)
    az network nic update \
        --resource-group "$AZLH_PROXY_VM_NAME" \
        --name "${AZLH_PROXY_VM_NAME}vmnic" \
        --network-security-group ""
    az network nsg delete \
        --resource-group "$AZLH_PROXY_VM_NAME" \
        --name "${AZLH_PROXY_VM_NAME}nsg"
}

az_proxy_is_connectable () {
    local CURRENT_SOURCE_ADDRESS=$(az network nsg rule show \
        --resource-group "$AZLH_PROXY_VM_NAME" \
        --nsg-name "$AZLH_PROXY_VM_NAME" \
        --name "$AZLH_PROXY_VM_NAME" \
        --query sourceAddressPrefix -o tsv)
    local ACTUAL_SOURCE_ADDRESS=$(curl -s ipinfo.io/ip)
    echo "$ACTUAL_SOURCE_ADDRESS (Public IP) -> $CURRENT_SOURCE_ADDRESS (NSG IP)"
    if [[ "$CURRENT_SOURCE_ADDRESS" != "$ACTUAL_SOURCE_ADDRESS" ]]; then
        echo "Connection not possible"
    else
        echo "Connection possible"
    fi
}

az_proxy_refresh_ip () {
    az network nsg rule update \
        --name "$AZLH_PROXY_VM_NAME" \
        --nsg-name "$AZLH_PROXY_VM_NAME" \
        --resource-group "$AZLH_PROXY_VM_NAME" \
        --source-address-prefixes $(curl -s ipinfo.io/ip)
}

##################################################
# Resource group helpers.                        #
##################################################
az_group_create () {
    local IDENTIFIER="$1"
    if [[ -z "$IDENTIFIER" ]]; then
        print_usage \
            "Resource group name" \
            "(Optional) Notes"
        return
    fi

    local CURRENT_DATE=$(date)
    local TAGS="created_on=${CURRENT_DATE// /_}"
    # If the user passes "notes" into the function then add
    # the notes tag.
    if [[ -n "$2" ]]; then
        local TAGS_NOTES="notes="$2""
    fi

    local RESOURCE_GROUP_NAME="$1"
    az group create \
        -n "$RESOURCE_GROUP_NAME" \
        -l "$AZLH_REGION" \
        --tags "$TAGS" "$TAGS_NOTES" > /dev/null
    echo "$RESOURCE_GROUP_NAME"
}

az_group_list () {
    if [[ -z "$AZLH_PREFIX" ]]; then
        echo "You must define AZLH_PREFIX"
        return
    fi

    az group list --query "[?starts_with(name,'$AZLH_PREFIX')].{name:name,location:location,tags:tags}" \
        | "$SCRIPT_PATH/parse_resource_group_info.py"
}

az_group_delete () {
    local RESOURCE_GROUP_NAME="$1"
    if [[ -z "$RESOURCE_GROUP_NAME" ]]; then
        print_usage "Resource group name"
        return
    fi

    az group delete -n "$RESOURCE_GROUP_NAME" -y --no-wait
}

az_group_delete_all () {
    if [[ -z "$AZLH_PREFIX" ]]; then
        echo "You must define AZLH_PREFIX"
        return
    fi

    az group list -o table |
        grep -E "^$AZLH_PREFIX" |
        grep -v "$AZLH_IGNORE" |
        awk '{print $1}' |
        xargs -n 1 az group delete -y --no-wait -n
}

##################################################
# Virtual machine helpers.                       #
##################################################
az_vm_create () {
    if [[ -z "$AZLH_PREFIX" ]]; then
        echo "You must define AZLH_PREFIX"
        return
    fi

    # Pass in the image URN as the first parameter, or default to Ubuntu Bionic.
    if [[ -z "$1" ]]; then
        print_usage \
            "Image name" \
            "(Optional) Notes" \
            "(Optional) Custom data"

        echo "Optionally set VM_SIZE env var for a non-default size (default Standard_DS1_v2)."
        echo "Optionally set ADMIN_PASSWORD env var for admin password (default none)."
        echo "Optionally set ACCEL_NET env var to enable accelerated networking."
        echo "Optionally set OSDISK_SIZE env var to os disk size in GB (default 32 GB)."
        echo "Optionally set MSI env var to enable managed service identity."
        return
    fi

    VM_SIZE="${VM_SIZE:-Standard_DS1_v2}"

    if [[ ! -z "$2" ]]; then
        local NOTES="$2"
    fi

    if [[ ! -z "$3" ]]; then
        local CUSTOM_DATA="$3"
    fi
    local IMAGE="$1"
    local NAME=$(resource_name)
    local RG_NAME=$(az_group_create "$NAME" "$NOTES")
    local VM_NAME="$NAME"
    local DNS_NAME="$NAME"
    local FULL_DNS_NAME=$(full_dns_name "$VM_NAME")
    local STORAGE_ACCOUNT_NAME="$NAME"

    # Create the storage account for boot diagnostics.
    az_storage_account_create "$STORAGE_ACCOUNT_NAME"

    # First check to see if this is maybe a custom image.
    local CUSTOM_IMAGE_ID=$(az image show -n "$IMAGE" -g "$IMAGE" --query "id" 2> /dev/null)
    if [[ ! -z "$CUSTOM_IMAGE_ID" ]]; then
        local IMAGE="${CUSTOM_IMAGE_ID//\"}"
    fi

    local ACCELERATED_NETWORKING="false"
    if [[ -n "$ACCEL_NET" ]]; then
        local ACCELERATED_NETWORKING="true"
    fi

    local AUTH_TYPE="ssh"
    if [[ -n "$ADMIN_PASSWORD" ]]; then
        local AUTH_TYPE="all"
    fi

    local OSDISK_SIZE_EFF="32"
    if [[ -n "$OSDISK_SIZE" ]]; then
        local OSDISK_SIZE_EFF="$OSDISK_SIZE"
    fi

    az network nsg create \
        --name "$VM_NAME" \
        --resource-group "$RG_NAME" > /dev/null
    az network nsg rule create \
        --name "$VM_NAME" \
        --nsg-name "$VM_NAME" \
        --priority 100 \
        --resource-group "$RG_NAME" \
        --access Allow --direction Inbound \
        --source-address-prefixes $(curl -s ipinfo.io/ip) \
        --destination-port-ranges 22 > /dev/null
    az network vnet create \
        --name "$VM_NAME" \
        --resource-group "$RG_NAME" > /dev/null
    az network vnet subnet create \
        --name "$VM_NAME" \
        --vnet-name "$VM_NAME" \
        --resource-group "$RG_NAME" \
        --address-prefixes "10.0.0.0/24" \
        --network-security-group $(az network nsg show \
            --resource-group "$RG_NAME" \
            --name "$VM_NAME" --query id -o tsv) > /dev/null

    IFS='' read -r -d '' CMD << EOF
        az vm create \
            -g "$RG_NAME" \
            -n "$VM_NAME" \
            -l "$AZLH_REGION" \
            --ssh-key-value "$AZLH_SSH_KEY_FILE" \
            --admin-username "$AZLH_ADMIN_USERNAME" \
            --admin-password "$ADMIN_PASSWORD" \
            --authentication-type "$AUTH_TYPE" \
            --public-ip-address-dns-name "$DNS_NAME" \
            --custom-data "$CUSTOM_DATA" \
            --image "$IMAGE" \
            --size "$VM_SIZE" \
            --accelerated-networking "$ACCELERATED_NETWORKING" \
            --os-disk-size-gb "$OSDISK_SIZE_EFF" \
            --boot-diagnostics-storage "$STORAGE_ACCOUNT_NAME" \
            --vnet-name "$VM_NAME" \
            --subnet "$VM_NAME" \
            --nsg "$VM_NAME"
EOF

    if [[ -n "$MSI" ]]; then
        local SCOPE=$(az group show -n "$RG_NAME" --query id -o tsv)
        local CMD="$(echo "$CMD" | tr -d '\n') --assign-identity --scope $SCOPE"
    fi

    bash -c "$CMD" > /dev/null 2>&1

    IMAGE_PUBLISHER=$(az vm show \
        --resource-group "$RG_NAME" \
        --name "$VM_NAME" \
        --query "storageProfile.imageReference.publisher" -o tsv)
    IMAGE_OFFER=$(az vm show \
        --resource-group "$RG_NAME" \
        --name "$VM_NAME" \
        --query "storageProfile.imageReference.offer" -o tsv)
    IMAGE_SKU=$(az vm show \
        --resource-group "$RG_NAME" \
        --name "$VM_NAME" \
        --query "storageProfile.imageReference.sku" -o tsv)
    IMAGE_VERSION=$(az vm show \
        --resource-group "$RG_NAME" \
        --name "$VM_NAME" \
        --query "storageProfile.imageReference.version" -o tsv)
    IMAGE_EXACT_VERSION=$(az vm show \
        --resource-group "$RG_NAME" \
        --name "$VM_NAME" \
        --query "storageProfile.imageReference.exactVersion" -o tsv)

    az group update \
        --name "$RG_NAME" \
        --set tags."image=$IMAGE_PUBLISHER:$IMAGE_OFFER:$IMAGE_SKU:$IMAGE_VERSION ($IMAGE_EXACT_VERSION)" \
        --set tags.fqdn="$FULL_DNS_NAME" > /dev/null

    echo "Resource group:  $RG_NAME"
    echo "VM name:         $VM_NAME"
    echo "Size:            $VM_SIZE"
    echo "Admin:           $AZLH_ADMIN_USERNAME"
    echo "SSH key file:    $AZLH_SSH_KEY_FILE"
    echo "DNS name:        $FULL_DNS_NAME"
    echo "Image:           $IMAGE"
}

az_vm_create_default () {
    local NOTES=""
    if [[ -n "$1" ]]; then
        local NOTES="$1"
    fi

    az_vm_create "$AZLH_DEFAULT_IMAGE_NAME" "$NOTES"
}

az_vm_is_connectable () {
    local VM_NAME="$1"
    if [[ -z "$VM_NAME" ]]; then
        print_usage \
            "VM name"
        return
    fi

    local CURRENT_SOURCE_ADDRESS=$(az network nsg rule show \
        --resource-group "$VM_NAME" \
        --nsg-name "$VM_NAME" \
        --name "$VM_NAME" \
        --query sourceAddressPrefix -o tsv)
    local ACTUAL_SOURCE_ADDRESS=$(curl -s ipinfo.io/ip)
    echo "$ACTUAL_SOURCE_ADDRESS (Public IP) -> $CURRENT_SOURCE_ADDRESS (NSG IP)"
    if [[ "$CURRENT_SOURCE_ADDRESS" != "$ACTUAL_SOURCE_ADDRESS" ]]; then
        echo "Connection not possible"
    else
        echo "Connection possible"
    fi
}

az_vm_refresh_ip () {
    local VM_NAME="$1"
    if [[ -z "$VM_NAME" ]]; then
        print_usage \
            "VM name"
        return
    fi

    az network nsg rule update \
        --name "$VM_NAME" \
        --nsg-name "$VM_NAME" \
        --resource-group "$VM_NAME" \
        --source-address-prefixes $(curl -s ipinfo.io/ip) > /dev/null
}

az_vm_create_default_custom_data () {
    if [[ -z "$1" ]]; then
        echo "You must specify custom data"
        return
    fi

    if [[ -n "$2" ]]; then
        local NOTES="$2"
    fi

    local CUSTOM_DATA="$1"

    az_vm_create "$AZLH_DEFAULT_IMAGE_NAME" "$NOTES" "$CUSTOM_DATA"
}

az_vm_image_list_sku_ubuntu () {
    az vm image list-skus --publisher Canonical --offer UbuntuServer -l "$AZLH_REGION" -o table
}

az_vm_image_list_version_ubuntu () {
    local SKU_NAME="$1"
    if [[ -z "$SKU_NAME" ]]; then
        print_usage "SKU name"
        return
    fi

    az vm image list --publisher Canonical --offer UbuntuServer -l "$AZLH_REGION" --sku "$SKU_NAME" --all -o table
}

az_vm_ovf_dump () {
    if [[ -z "$1" ]]; then
        print_usage "VM name"
        return
    fi

    local VM_NAME="$1"

    az_vm_ssh "$VM_NAME" "sudo cat /var/lib/waagent/ovf-env.xml" |
        xmllint --format -
}

az_vm_ssh () {
    if [[ -z "$1" ]]; then
        print_usage \
            "VM name" \
            "(Optional) SSH command"
        return
    fi

    local VM_NAME="$1"
    local DNS_NAME=$(full_dns_name "$VM_NAME")

    if [[ -n "$2" ]]; then
        local SSH_COMMAND="$2"
    fi

    ssh -J "$AZLH_ADMIN_USERNAME"@"$AZLH_PROXY_VM_FQDN" "$AZLH_ADMIN_USERNAME"@"$DNS_NAME" "$SSH_COMMAND"
}

az_vm_scp_out () {
    if [[ -z "$1" ]]; then
        print_usage \
            "Target server" \
            "Source local file path" \
            "Destination remote file path"
        return
    elif [[ -z "$2" ]]; then
        print_usage \
            "Target server" \
            "Source local file path" \
            "Destination remote file path"
        return
    elif [[ -z "$3" ]]; then
        print_usage \
            "Target server" \
            "Source local file path" \
            "Destination remote file path"
        return
    fi

    local VM_NAME="$1"
    local SOURCE_FILE="$2"
    local DESTINATION_FILE="$3"

    scp -r -o \
        ProxyJump="$AZLH_ADMIN_USERNAME"@$(az_proxy_server) \
        "$SOURCE_FILE" \
        "$AZLH_ADMIN_USERNAME"@$(full_dns_name "$VM_NAME"):"$DESTINATION_FILE"
}

az_vm_deb_install () {
    if [[ -z "$1" ]]; then
        print_usage \
            "Target server" \
            "Source deb file"
        return
    elif [[ -z "$2" ]]; then
        print_usage \
            "Target server" \
            "Source deb file"
        return
    fi

    local VM_NAME="$1"
    local SOURCE_DEB="$2"
    local SOURCE_DEB_FILENAME=$(python3 -c "print('$SOURCE_DEB'.split('/')[-1])")

    # Copy the deb to the remote server.
    az_vm_scp_out \
        "$VM_NAME" \
        "$SOURCE_DEB" \
        "~"

    az_vm_ssh \
        "$VM_NAME" \
        "sudo apt install -y ~/$SOURCE_DEB_FILENAME"
}

az_vm_yum_install () {
    if [[ -z "$1" ]]; then
        print_usage \
            "Target server" \
            "Source rpm file"
        return
    elif [[ -z "$2" ]]; then
        print_usage \
            "Target server" \
            "Source rpm file"
        return
    fi

    local VM_NAME="$1"
    local SOURCE_RPM="$2"
    local SOURCE_RPM_FILENAME=$(python3 -c "print('$SOURCE_RPM'.split('/')[-1])")

    # Copy the deb to the remote server.
    az_vm_scp_out \
        "$VM_NAME" \
        "$SOURCE_RPM" \
        "~"

    az_vm_ssh \
        "$VM_NAME" \
        "sudo yum install -y ~/$SOURCE_RPM_FILENAME"
}

az_vm_rpm_install () {
    if [[ -z "$1" ]]; then
        print_usage \
            "Target server" \
            "Source rpm file"
        return
    elif [[ -z "$2" ]]; then
        print_usage \
            "Target server" \
            "Source rpm file"
        return
    fi

    local VM_NAME="$1"
    local SOURCE_RPM="$2"
    local SOURCE_RPM_FILENAME=$(python3 -c "print('$SOURCE_RPM'.split('/')[-1])")

    # Copy the deb to the remote server.
    az_vm_scp_out \
        "$VM_NAME" \
        "$SOURCE_RPM" \
        "~"

    az_vm_ssh \
        "$VM_NAME" \
        "sudo rpm -ivh ~/$SOURCE_RPM_FILENAME"
}

az_vm_rpm_update () {
    if [[ -z "$1" ]]; then
        print_usage \
            "Target server" \
            "Source rpm file"
        return
    elif [[ -z "$2" ]]; then
        print_usage \
            "Target server" \
            "Source rpm file"
        return
    fi

    local VM_NAME="$1"
    local SOURCE_RPM="$2"
    local SOURCE_RPM_FILENAME=$(python3 -c "print('$SOURCE_RPM'.split('/')[-1])")

    # Copy the deb to the remote server.
    az_vm_scp_out \
        "$VM_NAME" \
        "$SOURCE_RPM" \
        "~"

    az_vm_ssh \
        "$VM_NAME" \
        "sudo rpm -Uvh --force ~/$SOURCE_RPM_FILENAME"
}

az_vm_boot_log_dump () {
    if [[ -z "$1" ]]; then
        print_usage "VM name required"
        return
    fi

    local VM_NAME="$1"

    az vm boot-diagnostics get-boot-log --name "$VM_NAME" -g "$VM_NAME"
}

##################################################
# Storage helpers.                               #
##################################################
az_storage_account_create () {
    if [[ -z "$1" ]]; then
        print_usage "Storage account name (same as resource group)"
        return
    fi

    local RES_NAME=$(printf "$1" | tr '[:upper:]' '[:lower:]')

    az storage account create \
        --name "$RES_NAME" \
        -l "$AZLH_REGION" \
        --kind "StorageV2" \
        -g "$RES_NAME" > /dev/null
}

##################################################
# Network helpers.                               #
##################################################
az_network_public_ip_list () {
    if [[ -z "$AZLH_PREFIX" ]]; then
        echo "You must define AZLH_PREFIX"
        return
    fi

    az_network_public_ip_list | grep -E "^$AZLH_PREFIX" --color=never
}

##################################################
# Image helpers.                                 #
##################################################
az_image_list () {
    if [[ -z "$AZLH_PREFIX" ]]; then
        echo "You must define AZLH_PREFIX"
        return
    fi

    az image list -o table | grep -E --color=never "$AZLH_PREFIX" | awk '{print $3 " (" $5 ")"}'
}

az_image_create_from_vm () {
    if [[ -z "$1" ]]; then
        print_usage "VM name"

        echo "Optionally set VM_GEN env var for a non-default generation (default V1, allowed V1 or V2)."
        echo "Optionally set NO_DEPROVISION so waagent does not deprovision (set to anything, does not matter)."
        return
    fi

    local VM_NAME="$1"
    local RG_NAME="$VM_NAME"

    VM_GEN="${VM_GEN:-V1}"

    if [[ -z "$NO_DEPROVISION" ]]; then
        # Deprovision the VM.
        az_vm_ssh "$VM_NAME" "sudo waagent -deprovision+user -force"
    fi

    # Create the image.
    az vm deallocate --resource-group "$RG_NAME" --name "$VM_NAME"
    az vm generalize --resource-group "$RG_NAME" --name "$VM_NAME"
    az image create \
        --resource-group "$RG_NAME" \
        --source "$VM_NAME" \
        -l "$AZLH_REGION" \
        --hyper-v-generation "$VM_GEN" \
        --name "$VM_NAME" > /dev/null
}
