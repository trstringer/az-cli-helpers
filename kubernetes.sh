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

    az_group_create "$NAME" > /dev/null

    NOTES="$1"
    if [[ -n "$NOTES" ]]; then
        az_group_notes_add "$NAME" "$NOTES"
    fi

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

    az_group_create "$NAME" > /dev/null

    NOTES="$1"
    if [[ -n "$NOTES" ]]; then
        az_group_notes_add "$NAME" "$NOTES"
    fi

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
    az_aks_engine_create "minimal" "$1"
}

az_aks_engine_create_medium () {
    az_aks_engine_create "medium" "$1"
}

az_aks_engine_create () {
    if [[ -z "$AZLH_PREFIX" ]]; then
        echo "You must define AZLH_PREFIX"
        return
    fi

    local CLUSTER_SIZE="$1"
    if [[ -z "$CLUSTER_SIZE" ]]; then
        print_usage "Desired cluster size (minimal, medium, large)"
        return
    fi

    local API_MODEL="${SCRIPT_PATH}/aks-engine-${CLUSTER_SIZE}.json"
    if [[ ! -f "$API_MODEL" ]]; then
        echo "$API_MODEL not found"
        return
    fi

    if [[ -n "$RESOURCE_NAME_INTERNAL" ]]; then
        local NAME="$RESOURCE_NAME_INTERNAL"
    else
        local NAME="${RESOURCE_NAME:-$(resource_name)}"
    fi

    az_group_create "$NAME" > /dev/null

    NOTES="$2"
    if [[ -n "$NOTES" ]]; then
        az_group_notes_add "$NAME" "$NOTES"
    fi

    aks-engine deploy \
        --resource-group "$NAME" \
        --api-model "$API_MODEL" \
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
    az_aks_engine_arc_create "minimal" "$1"
}

az_aks_engine_arc_create_medium () {
    az_aks_engine_arc_create "medium" "$1"
}

az_aks_engine_arc_create () {
    if [[ -z "$AZLH_PREFIX" ]]; then
        echo "You must define AZLH_PREFIX"
        return
    fi

    local CLUSTER_SIZE="$1"
    if [[ -z "$CLUSTER_SIZE" ]]; then
        print_usage "Desired cluster size (minimal, medium, large)"
        return
    fi

    local NAME="${RESOURCE_NAME:-$(resource_name)}"
    RESOURCE_NAME_INTERNAL="$NAME"

    if [[ "$CLUSTER_SIZE" == "minimal" ]]; then
        az_aks_engine_create_minimal "$2"
    elif [[ "$CLUSTER_SIZE" == "medium" ]]; then
        az_aks_engine_create_medium "$2"
    else
        echo "Unknown cluster size '$CLUSTER_SIZE'"
        return
    fi

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
    local ADDITIONAL_OSM_OPTIONS="$1"
    if [[ -n "$ADDITIONAL_OSM_OPTIONS" ]]; then
        ADDITIONAL_OSM_OPTIONS="--set=${ADDITIONAL_OSM_OPTIONS}"
    fi

    echo "Installing OSM on the cluster"
    ROOT_OSM=$(readlink -f $(which osm))
    if echo "$ROOT_OSM" | grep dev; then
        echo "In a dev build. Building images"

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
        echo "Using OSM CLI from git commit $CURRENT_OSM_GIT_COMMIT"

        CURRENT_CLUSTER=$(kubectl config current-context)
        echo "Using cluster $CURRENT_CLUSTER"

        echo "Creating Azure Container Registry"
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
        sed -i 's|#export USE_PRIVATE_REGISTRY=false|export USE_PRIVATE_REGISTRY=true|' ./.env

        local OSM_NAMESPACE="osm-system"
        if ! kubectl get ns "$OSM_NAMESPACE"; then
            kubectl create ns "$OSM_NAMESPACE"
        fi

        ./scripts/create-container-registry-creds.sh "$OSM_NAMESPACE"
        source ./.env
        make build
        make docker-push

        local IMAGE_TAG="${CTR_TAG:-latest}"

        osm install \
            --set=OpenServiceMesh.image.registry="${CURRENT_CLUSTER}.azurecr.io/osm" \
            --set=OpenServiceMesh.image.tag="$IMAGE_TAG" \
            --set=OpenServiceMesh.imagePullSecrets[0].name="acr-creds" \
            --set=OpenServiceMesh.enablePermissiveTrafficPolicy=true \
            --set=OpenServiceMesh.deployPrometheus=true \
            --set=OpenServiceMesh.deployGrafana=true \
            --set=OpenServiceMesh.deployJaeger=true \
            "$ADDITIONAL_OSM_OPTIONS"

        cd "$CURRENT_DIR"
    else
        echo "Not in a dev build, using default images"
        osm install \
            --set=OpenServiceMesh.enablePermissiveTrafficPolicy=true \
            --set=OpenServiceMesh.deployPrometheus=true \
            --set=OpenServiceMesh.deployGrafana=true \
            --set=OpenServiceMesh.deployJaeger=true \
            "$ADDITIONAL_OSM_OPTIONS"
    fi
}

az_osm_app_install () {
    echo "Installing sample OSM app"

    kubectl create namespace bookstore
    kubectl create namespace bookbuyer
    kubectl create namespace bookthief
    kubectl create namespace bookwarehouse

    osm namespace add bookstore
    osm namespace add bookbuyer
    osm namespace add bookthief
    osm namespace add bookwarehouse

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
    echo "Using OSM CLI from git commit $CURRENT_OSM_GIT_COMMIT"

    CURRENT_CLUSTER=$(kubectl config current-context)
    echo "Using cluster $CURRENT_CLUSTER"

    echo "Creating Azure Container Registry if it does not exist"
    if ! az acr show --name "$CURRENT_CLUSTER"; then
        echo "Creating ACR"
        az acr create \
            --resource-group "$CURRENT_CLUSTER" \
            --name "$CURRENT_CLUSTER" \
            --sku basic \
            --admin-enabled
        az acr login \
            --name "$CURRENT_CLUSTER"
    fi

    cp ./.env.example ./.env
    sed -i "s|localhost:5000|${CURRENT_CLUSTER}.azurecr.io/osm|g" ./.env
    sed -i "s|CTR_REGISTRY_PASSWORD=|CTR_REGISTRY_PASSWORD='$(az acr credential show --name $CURRENT_CLUSTER --query 'passwords[0].value' -o tsv)'|g" ./.env
    sed -i 's|# export CTR_REGISTRY_CREDS_NAME=acr-creds|export CTR_REGISTRY_CREDS_NAME=acr-creds|' ./.env
    sed -i 's|#export USE_PRIVATE_REGISTRY=false|export USE_PRIVATE_REGISTRY=true|' ./.env

    local OSM_NAMESPACE="osm-system"
    if ! kubectl get ns "$OSM_NAMESPACE"; then
        kubectl create ns "$OSM_NAMESPACE"
    fi

    ./scripts/create-container-registry-creds.sh "$OSM_NAMESPACE"
    source ./.env
    make build
    make docker-push

    local IMAGE_TAG="${CTR_TAG:-latest}"

    BOOKBUYER_MANIFEST="${OSM_TEMP_PATH}/docs/example/manifests/apps/bookbuyer.yaml"
    ./scripts/create-container-registry-creds.sh "bookbuyer"
    sed -i \
        "/\s\+containers:/i\      imagePullSecrets:\n        - name: acr-creds" \
        "$BOOKBUYER_MANIFEST"
    sed -i \
        "s|openservicemesh/bookbuyer.*$|${CURRENT_CLUSTER}.azurecr.io/osm/bookbuyer:${IMAGE_TAG}|g" \
        "$BOOKBUYER_MANIFEST"

    BOOKTHIEF_MANIFEST="${OSM_TEMP_PATH}/docs/example/manifests/apps/bookthief.yaml"
    ./scripts/create-container-registry-creds.sh "bookthief"
    sed -i \
        "/\s\+containers:/i\      imagePullSecrets:\n        - name: acr-creds" \
        "$BOOKTHIEF_MANIFEST"
    sed -i \
        "s|openservicemesh/bookthief.*$|${CURRENT_CLUSTER}.azurecr.io/osm/bookthief:${IMAGE_TAG}|g" \
        "$BOOKTHIEF_MANIFEST"

    BOOKSTORE_MANIFEST="${OSM_TEMP_PATH}/docs/example/manifests/apps/bookstore.yaml"
    ./scripts/create-container-registry-creds.sh "bookstore"
    sed -i \
        "/\s\+containers:/i\      imagePullSecrets:\n        - name: acr-creds" \
        "$BOOKSTORE_MANIFEST"
    sed -i \
        "s|openservicemesh/bookstore.*$|${CURRENT_CLUSTER}.azurecr.io/osm/bookstore:${IMAGE_TAG}|g" \
        "$BOOKSTORE_MANIFEST"

    BOOKWAREHOUSE_MANIFEST="${OSM_TEMP_PATH}/docs/example/manifests/apps/bookwarehouse.yaml"
    ./scripts/create-container-registry-creds.sh "bookwarehouse"
    sed -i \
        "/\s\+containers:/i\      imagePullSecrets:\n        - name: acr-creds" \
        "$BOOKWAREHOUSE_MANIFEST"
    sed -i \
        "s|openservicemesh/bookwarehouse.*$|${CURRENT_CLUSTER}.azurecr.io/osm/bookwarehouse:${IMAGE_TAG}|g" \
        "$BOOKWAREHOUSE_MANIFEST"

    echo "Creating applications"
    kubectl apply -f "${OSM_TEMP_PATH}/docs/example/manifests/apps/bookbuyer.yaml"
    kubectl apply -f "${OSM_TEMP_PATH}/docs/example/manifests/apps/bookthief.yaml"
    kubectl apply -f "${OSM_TEMP_PATH}/docs/example/manifests/apps/bookstore.yaml"
    kubectl apply -f "${OSM_TEMP_PATH}/docs/example/manifests/apps/bookwarehouse.yaml"

    cd "$CURRENT_DIR"
}

az_osm_app_uninstall () {
    echo "Removing the sample OSM app from the cluster"

    osm namespace remove bookstore
    osm namespace remove bookbuyer
    osm namespace remove bookthief
    osm namespace remove bookwarehouse

    kubectl delete namespace bookstore
    kubectl delete namespace bookbuyer
    kubectl delete namespace bookthief
    kubectl delete namespace bookwarehouse
}

az_osm_cluster_smi_traffic_policy_mode_enable () {
    kubectl patch meshconfig osm-mesh-config \
        --namespace osm-system \
        --patch '{"spec":{"traffic":{"enablePermissiveTrafficPolicyMode":false}}}'  \
        --type=merge
}

az_osm_cluster_smi_traffic_policy_mode_disable () {
    kubectl patch meshconfig osm-mesh-config \
        --namespace osm-system \
        --patch '{"spec":{"traffic":{"enablePermissiveTrafficPolicyMode":true}}}'  \
        --type=merge
}

az_osm_arc_cluster_install () {
    local CURRENT_CLUSTER
    CURRENT_CLUSTER=$(kubectl config current-context)

    local OSM_VERSION
    OSM_VERSION="0.9.1"

    echo '{"osm.OpenServiceMesh.deployPrometheus": "true"}' > /tmp/osm-arc-config.json

    az_osm_cli_install_release "v${OSM_VERSION}"

    az k8s-extension create \
        --resource-group "$CURRENT_CLUSTER" \
        --cluster-name "$CURRENT_CLUSTER" \
        --cluster-type "connectedClusters" \
        --extension-type "Microsoft.openservicemesh" \
        --scope "cluster" \
        --release-train "pilot" \
        --name "osm" \
        --version "$OSM_VERSION" \
        --configuration-settings-file /tmp/osm-arc-config.json
}

az_osm_arc_monitoring_enable () {
    local CURRENT_CLUSTER
    CURRENT_CLUSTER=$(kubectl config current-context)

    osm namespace list |
        grep -v "NAMESPACE" |
        awk '{print $1}' |
        xargs -rn 1 osm metrics enable --namespace

    local WORKSPACE_ID
    WORKSPACE_ID=$(az monitor log-analytics workspace show \
        --resource-group "$CURRENT_CLUSTER" \
        --workspace-name "$CURRENT_CLUSTER" \
        --query id -o tsv)

    if [[ -z "$WORKSPACE_ID" ]]; then
        az monitor log-analytics workspace create \
            --resource-group "$CURRENT_CLUSTER" \
            --workspace-name "$CURRENT_CLUSTER"
        WORKSPACE_ID=$(az monitor log-analytics workspace show \
            --resource-group "$CURRENT_CLUSTER" \
            --workspace-name "$CURRENT_CLUSTER" \
            --query id -o tsv)
    fi

    az k8s-extension create \
        --cluster-name "$CURRENT_CLUSTER" \
        --resource-group "$CURRENT_CLUSTER" \
        --cluster-type connectedClusters \
        --extension-type Microsoft.AzureMonitor.Containers \
        --configuration-settings "logAnalyticsWorkspaceResourceID=${WORKSPACE_ID}"

    local NAMESPACES_TO_MONITOR
    NAMESPACES_TO_MONITOR=$(osm namespace list |
        grep -v "NAMESPACE" |
        awk '{print  "\"" $1 "\""}' |
        tr '\n' ',')
    NAMESPACES_TO_MONITOR=${NAMESPACES_TO_MONITOR::-1}

    cat <<EOF > /tmp/monitoring-config-map.yaml
kind: ConfigMap
apiVersion: v1
data:
  schema-version:
    #string.used by agent to parse OSM config. supported versions are {v1}. Configs with other schema versions will be rejected by the agent.
    v1
  config-version:
    #string.used by OSM addon team to keep track of this config file's version in their source control/repository (max allowed 10 chars, other chars will be truncated)
    ver1
  osm-metric-collection-configuration: |-
    # OSM metric collection settings
    [osm_metric_collection_configuration.settings]
        # Namespaces to monitor
        monitor_namespaces = [$NAMESPACES_TO_MONITOR]
metadata:
  name: container-azm-ms-osmconfig
  namespace: kube-system
EOF

    kubectl apply -f /tmp/monitoring-config-map.yaml
}

##################################################
# Arc helpers.                                   #
##################################################
az_arc_osm_install () {
    local CURRENT_CLUSTER
    CURRENT_CLUSTER=$(kubectl config current-context)

    az k8s-extension create \
        --resource-group "$CURRENT_CLUSTER" \
        --cluster-name "$CURRENT_CLUSTER" \
        --cluster-type connectedClusters \
        --extension-type "microsoft.openservicemesh" \
        --scope cluster \
        --release-train pilot \
        --name osm \
        --version "0.9.1"
}
