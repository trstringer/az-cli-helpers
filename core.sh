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

az_account_summary () {
    local USER=$(az account show --query "user.name" -o tsv)
    local SUBSCRIPTION=$(az account show --query "name" -o tsv)
    echo "$USER in '$SUBSCRIPTION'"
}

az_account_personal () {
    if [[ -n "$AZLH_ACCOUNT_PERSONAL" ]]; then
        az account set -s "$AZLH_ACCOUNT_PERSONAL"
    fi
}

az_account_work () {
    if [[ -n "$AZLH_ACCOUNT_WORK" ]]; then
        az account set -s "$AZLH_ACCOUNT_WORK"
    fi
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

    az_account_summary
    echo

    az group list --query "[?starts_with(name,'$AZLH_PREFIX')].{name:name,location:location,tags:tags}" \
        | "$SCRIPT_PATH/parse_resource_group_info.py"
}

az_group_delete () {
    if [[ -z "$1" ]]; then
        print_usage "Resource group name"
        return
    fi

    local RESOURCE_GROUP_NAME="$1"

    az group delete -n "$RESOURCE_GROUP_NAME" -y --no-wait

    if [[ -n "$AZLH_SSH_TUNNEL" ]]; then
        local PUBLIC_IP_ADDRESS=$(az_network_public_ip_from_vm "$RESOURCE_GROUP_NAME")
        sudo ip route del "$PUBLIC_IP_ADDRESS" dev "$AZLH_SSH_TUNNEL"
    fi
}

az_group_delete_all () {
    if [[ -z "$AZLH_PREFIX" ]]; then
        echo "You must define AZLH_PREFIX"
        return
    fi

    GROUPS_TO_DELETE=$(az group list -o table |
        grep -E "^$AZLH_PREFIX" |
        grep -vi "$AZLH_IGNORE" |
        awk '{print $1}')

    for GROUP in $GROUPS_TO_DELETE; do
        az_group_delete "$GROUP"
    done
}

az_group_notes_add () {
    local RG_NAME="$1"
    local NOTES="$2"
    if [[ -z "$NOTES" || -z "$RG_NAME" ]]; then
        print_usage \
            "Resource group name" \
            "Notes to add"
        return
    fi

    az tag update \
        --resource-id $(az group show \
            --name "$RG_NAME" \
            --query id -o tsv) \
        --operation merge \
        --tags notes="$NOTES" > /dev/null
}
