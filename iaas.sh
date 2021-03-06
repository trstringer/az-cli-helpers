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
        echo "Optionally set RESOURCE_NAME to override the resource name."
        echo "Optionally set EXACT_IMAGE_ID to specify setting the exact image ID."
        echo "Optionally set SKIP_RG_CREATE to skip the RG creation (must be pre-staged)."
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
    local NAME="${RESOURCE_NAME:-$(resource_name)}"
    if [[ ! -z "$SKIP_RG_CREATE" ]]; then
        local RG_NAME="$RESOURCE_NAME"
    else
        local RG_NAME=$(az_group_create "$NAME" "$NOTES")
    fi
    local VM_NAME="$NAME"
    local DNS_NAME="$NAME"
    local FULL_DNS_NAME=$(full_dns_name "$VM_NAME")
    local STORAGE_ACCOUNT_NAME="$NAME"

    # Create the storage account for boot diagnostics.
    az_storage_account_create "$STORAGE_ACCOUNT_NAME"

    # First check to see if this is maybe a custom image.
    if [[ ! -z "$EXACT_IMAGE_ID" ]]; then
        local CUSTOM_IMAGE_ID="$IMAGE"
    else
        local CUSTOM_IMAGE_ID=$(az image show -n "$IMAGE" -g "$IMAGE" --query "id" 2> /dev/null)
    fi
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

    IFS='' read -r -d '' CMD << EOF
        az vm create \
            -g "$RG_NAME" \
            -n "$VM_NAME" \
            -l "$AZLH_REGION" \
            --ssh-key-value $AZLH_SSH_KEY_FILE \
            --admin-username "$AZLH_ADMIN_USERNAME" \
            --admin-password "$ADMIN_PASSWORD" \
            --authentication-type "$AUTH_TYPE" \
            --public-ip-address-dns-name "$DNS_NAME" \
            --custom-data "$CUSTOM_DATA" \
            --image "$IMAGE" \
            --size "$VM_SIZE" \
            --accelerated-networking "$ACCELERATED_NETWORKING" \
            --os-disk-size-gb "$OSDISK_SIZE_EFF" \
            --boot-diagnostics-storage "$STORAGE_ACCOUNT_NAME"
EOF

    if [[ -n "$MSI" ]]; then
        local SCOPE=$(az group show -n "$RG_NAME" --query id -o tsv)
        local CMD="$(echo "$CMD" | tr -d '\n') --assign-identity --scope $SCOPE"
    fi

    bash -c "$CMD" > /dev/null

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

    if [[ -n "$AZLH_SSH_TUNNEL" ]]; then
        local PUBLIC_IP_ADDRESS=$(az_network_public_ip_from_vm "$VM_NAME")
        sudo ip route add "$PUBLIC_IP_ADDRESS" dev "$AZLH_SSH_TUNNEL"
    fi

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

az_vm_create_ubuntu_bionic () {
    local NOTES=""
    if [[ -n "$1" ]]; then
        local NOTES="$1"
    fi

    az_vm_create "Canonical:UbuntuServer:18.04-LTS:latest" "$NOTES"
}

az_vm_create_ubuntu_focal () {
    local NOTES=""
    if [[ -n "$1" ]]; then
        local NOTES="$1"
    fi

    az_vm_create "Canonical:0001-com-ubuntu-server-focal:20_04-lts:latest" "$NOTES"
}

az_vm_create_from_vm () {
    local SOURCE_VM="$1"
    if [[ -z "$SOURCE_VM" ]]; then
        print_usage \
            "Source VM" \
            "(Optional) Notes" \
            "(Optional) Custom data"
        return
    fi

    if [[ -n "$2" ]]; then
        local NOTES="$2"
    fi

    if [[ ! -z "$3" ]]; then
        local CUSTOM_DATA="$3"
    fi

    az_image_create_from_vm "$SOURCE_VM"
    az_vm_create "$SOURCE_VM" "$NOTES" "$CUSTOM_DATA"
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

    ssh -J "$AZLH_ADMIN_USERNAME"@"$AZLH_PROXY_SERVER_PRIVATE_IP" "$AZLH_ADMIN_USERNAME"@"$DNS_NAME" "$SSH_COMMAND"
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
        ProxyJump="$AZLH_ADMIN_USERNAME"@$AZLH_PROXY_SERVER_PRIVATE_IP \
        "$SOURCE_FILE" \
        "$AZLH_ADMIN_USERNAME"@$(full_dns_name "$VM_NAME"):"$DESTINATION_FILE"
}

az_vm_scp_in () {
    if [[ -z "$1" ]]; then
        print_usage \
            "Target server" \
            "Source remote file path" \
            "Destination local file path"
        return
    elif [[ -z "$2" ]]; then
        print_usage \
            "Target server" \
            "Source remote file path" \
            "Destination local file path"
        return
    elif [[ -z "$3" ]]; then
        print_usage \
            "Target server" \
            "Source remote file path" \
            "Destination local file path"
        return
    fi

    local VM_NAME="$1"
    local SOURCE_FILE="$2"
    local DESTINATION_FILE="$3"

    scp -r -o \
        ProxyJump="$AZLH_ADMIN_USERNAME"@$AZLH_PROXY_SERVER_PRIVATE_IP \
        "$AZLH_ADMIN_USERNAME"@$(full_dns_name "$VM_NAME"):"$SOURCE_FILE" \
        "$DESTINATION_FILE"
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
        "sudo apt install -y --allow-downgrades ~/$SOURCE_DEB_FILENAME"
}

az_vm_cloud_init_install () {
    local CUSTOM_SCRIPT="$1"

    # Create the base resource for the image creation.
    RESOURCE_NAME=$(resource_name) && \
    echo "Using $RESOURCE_NAME" && \
    az_vm_create_default && \

    # Build a new cloud-init deb package.
    CWD=$(pwd) && \
    cd ~/dev/cloud-init && \
    ./packages/bddeb && \

    # Install the new cloud-init pkg.
    cd "$CWD" && \
    az_vm_deb_install "$RESOURCE_NAME" ~/dev/cloud-init/cloud-init_all.deb && \

    # Source the custom script if there is anything to do.
    # The custom script is sourced, so it does not have to have executable
    # permissions. And because it is sourced you have access to RESOURCE_NAME.
    if [[ -n "$CUSTOM_SCRIPT" ]]; then
        source "$CUSTOM_SCRIPT"
    fi && \

    # Create a new VM from the VM.
    OLD_RESOURCE_NAME="$RESOURCE_NAME" && \
    unset RESOURCE_NAME && \
    az_vm_ssh "$OLD_RESOURCE_NAME" "sudo cloud-init clean --logs" && \

    if [[ -n "$NEW_RESOURCE_NAME" ]]; then
        RESOURCE_NAME="$NEW_RESOURCE_NAME"
    fi && \

    az_vm_create_from_vm "$OLD_RESOURCE_NAME" && \
    unset RESOURCE_NAME && \
    echo "Completed cloud-init build and install!"
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

az_vm_disk_recovery () {
    if [[ -z "$1" ]]; then
        print_usage "VM name required"
        return
    fi

    local RECOVERY_NAME="$1"
    local NEW_RESOURCE_NAME="$(resource_name)"

    RESOURCE_NAME="$NEW_RESOURCE_NAME" az_vm_create_default "recovery VM for $RECOVERY_NAME"

    TARGET_DISK_ID=$(az vm show \
        --resource-group "$RECOVERY_NAME" \
        --name "$RECOVERY_NAME" \
        --query "storageProfile.osDisk.managedDisk.id" -o tsv)
    TARGET_DISK_NAME=$(az disk show \
        --ids "$TARGET_DISK_ID" \
        --query "name" -o tsv)
    DISK_COPY_NAME="${TARGET_DISK_NAME}copy"

    az disk create \
        --resource-group "$NEW_RESOURCE_NAME" \
        --name "$DISK_COPY_NAME" \
        --source "$TARGET_DISK_ID" > /dev/null

    az vm disk attach \
        --resource-group "$NEW_RESOURCE_NAME" \
        --vm-name "$NEW_RESOURCE_NAME" \
        --lun 0 \
        --name "$DISK_COPY_NAME"

    NEW_FQDN="$(full_dns_name $NEW_RESOURCE_NAME)"

    MOUNT_PATH="/mnt/recovery"
    az_vm_ssh $NEW_RESOURCE_NAME "sudo mkdir ${MOUNT_PATH}"
    az_vm_ssh $NEW_RESOURCE_NAME "sudo mount /dev/sdc1 ${MOUNT_PATH}"

    echo "Disk available on ${NEW_FQDN} at ${MOUNT_PATH}"
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

az_network_public_ip_from_vm () {
    if [[ -z "$1" ]]; then
        echo "You must specify the VM name to generate the fqdn for"
        return
    fi

    local VM_NAME="$1"

    az network public-ip show \
        --ids $(az network nic show \
            --ids $(az vm show \
                --name "$VM_NAME" \
                --resource-group "$VM_NAME" \
                --query "networkProfile.networkInterfaces[0].id" -o tsv) \
            --query "ipConfigurations[0].publicIpAddress.id" -o tsv) \
        --query "ipAddress" -o tsv
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

    az_vm_ssh "$VM_NAME" "sudo cloud-init clean --logs"

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
