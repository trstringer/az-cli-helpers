SCRIPT_PATH="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

##################################################
# Kubernetes helpers.                            #
##################################################
az_aks_engine_create_minimal () {
    if [[ -z "$AZLH_PREFIX" ]]; then
        echo "You must define AZLH_PREFIX"
        return
    fi

    local NAME="${RESOURCE_NAME:-$(resource_name)}"

    aks-engine deploy \
        --resource-group "$NAME" \
        --api-model "${SCRIPT_PATH}/aks-engine-minimal.json" \
        --dns-prefix "$NAME" \
        --location "$AZLH_REGION"

    # Update kubectl config to add the new cluster and set the new
    # cluster as the current context.
    KUBE_CONFIG_TEMP="${HOME}/.kube/config"
    KUBE_CONFIG_TEMP_OLD="${KUBE_CONFIG_TEMP}.old"
    if [[ -f "$KUBE_CONFIG_TEMP" ]]; then
        mv "$KUBE_CONFIG_TEMP" "$KUBE_CONFIG_TEMP_OLD"
    fi
    KUBECONFIG="${KUBE_CONFIG_TEMP_OLD}:${HOME}/_output/${NAME}/kubeconfig/kubeconfig.${AZLH_REGION}.json" \
        kubectl config view --flatten > "$KUBE_CONFIG_TEMP"
    kubectl config use-context "$NAME"
}
