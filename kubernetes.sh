SCRIPT_PATH="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

##################################################
# Kubernetes helpers.                            #
##################################################
az_aks_create_minimal () {
    if [[ -z "$AZLH_PREFIX" ]]; then
        echo "You must define AZLH_PREFIX"
        return
    fi

    local NAME="${RESOURCE_NAME:-$(resource_name)}"

    az_group_create "$NAME"
    az aks create \
        --resource-group "$NAME" \
        --name "$NAME" \
        --node-count 1

    az aks get-credentials \
        --resource-group "$NAME" \
        --name "$NAME" \
        --overwrite-existing
}

az_aks_create_medium () {
    if [[ -z "$AZLH_PREFIX" ]]; then
        echo "You must define AZLH_PREFIX"
        return
    fi

    local NAME="${RESOURCE_NAME:-$(resource_name)}"

    az_group_create "$NAME"
    az aks create \
        --resource-group "$NAME" \
        --name "$NAME" \
        --node-count 5

    az aks get-credentials \
        --resource-group "$NAME" \
        --name "$NAME" \
        --overwrite-existing
}

az_aks_engine_create_minimal () {
    if [[ -z "$AZLH_PREFIX" ]]; then
        echo "You must define AZLH_PREFIX"
        return
    fi

    if [[ -n "$RESOURCE_NAME_INTERNAL" ]]; then
        local NAME="$RESOURCE_NAME_INTERNAL"
    else
        local NAME="${RESOURCE_NAME:-$(resource_name)}"
    fi

    az_group_create "$NAME"
    aks-engine deploy \
        --resource-group "$NAME" \
        --api-model "${SCRIPT_PATH}/aks-engine-minimal.json" \
        --dns-prefix "$NAME" \
        --location "$AZLH_REGION"

    # Update kubectl config to add the new cluster and set the new
    # cluster as the current context.
    local KUBE_CONFIG_TEMP="${HOME}/.kube/config"
    local KUBE_CONFIG_TEMP_OLD="${KUBE_CONFIG_TEMP}.old"
    if [[ -f "$KUBE_CONFIG_TEMP" ]]; then
        mv "$KUBE_CONFIG_TEMP" "$KUBE_CONFIG_TEMP_OLD"
    fi
    KUBECONFIG="${KUBE_CONFIG_TEMP_OLD}:${HOME}/_output/${NAME}/kubeconfig/kubeconfig.${AZLH_REGION}.json" \
        kubectl config view --flatten > "$KUBE_CONFIG_TEMP"
    chmod 600 "$KUBE_CONFIG_TEMP"
    kubectl config use-context "$NAME"
}

az_aks_engine_arc_create_minimal () {
    if [[ -z "$AZLH_PREFIX" ]]; then
        echo "You must define AZLH_PREFIX"
        return
    fi

    local NAME="${RESOURCE_NAME:-$(resource_name)}"
    RESOURCE_NAME_INTERNAL="$NAME"

    az_aks_engine_create_minimal

    while true; do
        echo "$(date) - Waiting for cluster to come up"
        if kubectl get no; then
            break
        fi
        sleep 5
    done

    while true; do
        echo "$(date) - Attempting to connect Kubernetes cluster to Arc"
        if az connectedk8s connect \
                --resource-group "$NAME" \
                --name "$NAME"; then
            break
        fi

        # If the helm install failed, then remove it and try again.
        az connectedk8s delete \
            --resource-group "$NAME" \
            --name "$NAME" \
            --yes
        sleep 5
    done
}
