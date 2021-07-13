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

##################################################
# Open Service Mesh helpers.                     #
##################################################
az_osm_release_list () {
    curl -s https://api.github.com/repos/openservicemesh/osm/releases |
        jq ".[].name" -r |
        tac
}

az_osm_cli_install_release () {
    local OSM_TEMP_PATH="/tmp/osm"
    local OSM_DOWNLOAD_NAME="osm.tar.gz"
    if [[ -d "$OSM_TEMP_PATH" ]]; then
        rm -rf "$OSM_TEMP_PATH"
    fi

    RELEASE="$1"
    if [[ -z "$RELEASE" ]]; then
        print_usage "Release"
        return
    fi
    echo "Installing release $RELEASE"

    mkdir "$OSM_TEMP_PATH"
    local CURRENT_DIR=$(pwd)
    cd "$OSM_TEMP_PATH"
    curl -sL \
        -o "$OSM_DOWNLOAD_NAME" \
        "https://github.com/openservicemesh/osm/releases/download/${RELEASE}/osm-${RELEASE}-linux-amd64.tar.gz"
    tar -xzf "./${OSM_DOWNLOAD_NAME}"
    cp ./linux-amd64/osm ~/bin/osm-release
    if [[ -e "${HOME}/bin/osm" ]]; then
        rm "${HOME}/bin/osm"
    fi
    ln -s "${HOME}/bin/osm-release" "${HOME}/bin/osm"

    cd "$CURRENT_DIR"
}

az_osm_cli_install_dev () {
    local OSM_TEMP_PATH="/tmp/osm"
    if [[ -d "$OSM_TEMP_PATH" ]]; then
        rm -rf "$OSM_TEMP_PATH"
    fi

    local GIT_REF="$1"
    if [[ -z "$GIT_REF" ]]; then
        print_usage \
            "Git ref (branch, tag, commit SHA) to install from. Use 'main' for default"

        echo "Optionally set OSM_REPO for a non-default git repo (default git@github.com:openservicemesh/osm.git)"
        return
    fi

    local REPO="${OSM_REPO:-git@github.com:openservicemesh/osm.git}"

    git clone "$REPO" "$OSM_TEMP_PATH"
    local CURRENT_DIR=$(pwd)
    cd "$OSM_TEMP_PATH"
    git checkout "$GIT_REF"
    make build-osm

    mv ./bin/osm ~/bin/osm-dev
    if [[ -e "${HOME}/bin/osm" ]]; then
        rm "${HOME}/bin/osm"
    fi
    ln -s "${HOME}/bin/osm-dev" "${HOME}/bin/osm"

    cd "$CURRENT_DIR"
}

az_osm_cluster_install () {
    local OSM_TEMP_PATH="/tmp/osm"
    if [[ -d "$OSM_TEMP_PATH" ]]; then
        rm -rf "$OSM_TEMP_PATH"
    fi

    local REPO="${OSM_REPO:-git@github.com:openservicemesh/osm.git}"
    local CURRENT_OSM_GIT_COMMIT=$(osm version |
        tr ";" "\n" |
        grep Commit |
        awk '{print $2}')

    git clone "$REPO" "$OSM_TEMP_PATH"
    local CURRENT_DIR=$(pwd)
    cd "$OSM_TEMP_PATH"
    git checkout "$CURRENT_OSM_GIT_COMMIT"

    echo "Installing OSM on the cluster"
    ROOT_OSM=$(readlink -f $(which osm))
    if echo "$ROOT_OSM" | grep dev; then
        echo "In a dev build. Building images"
        echo "Using OSM CLI from git commit $CURRENT_OSM_GIT_COMMIT"
        CURRENT_CLUSTER=$(kubectl config current-context)
        echo "Using cluster $CURRENT_CLUSTER"
        az acr create \
            --resource-group "$CURRENT_CLUSTER" \
            --name "$CURRENT_CLUSTER" \
            --sku basic \
            --admin-enabled
        az acr login \
            --name "$CURRENT_CLUSTER"

        cp ./.env.example ./.env
        sed -i "s|localhost:5000|${CURRENT_CLUSTER}.azurecr.io/osm|g" ./.env
        sed -i "s|CTR_REGISTRY_PASSWORD=|CTR_REGISTRY_PASSWORD='$(az acr credential show --name $CURRENT_CLUSTER --query 'passwords[0].value' -o tsv)'|g" ./.env
        sed -i 's|# export CTR_REGISTRY_CREDS_NAME=acr-creds|export CTR_REGISTRY_CREDS_NAME=acr-creds|' ./.env

        local OSM_NAMESPACE="osm-system"
        if ! kubectl get ns "$OSM_NAMESPACE"; then
            kubectl create ns "$OSM_NAMESPACE"
        fi

        ./scripts/create-container-registry-creds.sh "$OSM_NAMESPACE"
        source ./.env
        make build
        make docker-push

        osm install --set \
            OpenServiceMesh.image.registry="${CURRENT_CLUSTER}.azurecr.io/osm",OpenServiceMesh.image.tag=latest,OpenServiceMesh.imagePullSecrets[0].name="acr-creds"
    else
        echo "Not in a dev build, using default images"
        osm install
    fi

    cd "$CURRENT_DIR"
}
