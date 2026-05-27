#!/usr/bin/env bash

set -euo pipefail

CLUSTER_NAME=""
CHART=""
REPO_ROOT=""

parse_flags() {
  while test $# -gt 0; do
    case "$1" in
    --cluster-name)
      shift; CLUSTER_NAME="$1"
      ;;
    --path-cluster-chart)
      shift; CHART="$1"
      ;;
    --repo-root)
      shift; REPO_ROOT="$1"
      ;;
    esac

    shift
  done
}

parse_flags "$@"

kind create cluster \
  --name "$CLUSTER_NAME" \
  --config <(helm template $CHART)

NAMESPACE="${NAMESPACE:-delivery}"

kubectl create ns $NAMESPACE
kubectl config set-context --current --namespace=$NAMESPACE

# Resolve chart references:
# - delivery-service, bootstrapping and extensions come from the delivery-service component
#   (which is versioned independently and more up-to-date than the top-level ocm-gear component)
# - delivery-dashboard and postgresql come from the top-level ocm-gear component
OCM_GEAR_COMPONENT_REF="europe-docker.pkg.dev/gardener-project/releases//ocm.software/ocm-gear"
OCM_GEAR_DS_COMPONENT_REF="europe-docker.pkg.dev/gardener-project/releases//ocm.software/ocm-gear/delivery-service"
OCM_GEAR_VERSION="${OCM_GEAR_VERSION:-$(ocm show versions ${OCM_GEAR_COMPONENT_REF} | tail -1)}"
OCM_GEAR_DS_VERSION="${OCM_GEAR_DS_VERSION:-$(ocm show versions ${OCM_GEAR_DS_COMPONENT_REF} | tail -1)}"
COMPONENT_DESCRIPTORS=$(ocm get cv ${OCM_GEAR_COMPONENT_REF}:${OCM_GEAR_VERSION} -o yaml -r)
DS_COMPONENT_DESCRIPTORS=$(ocm get cv ${OCM_GEAR_DS_COMPONENT_REF}:${OCM_GEAR_DS_VERSION} -o yaml -r)
echo "Installing OCM-Gear with version $OCM_GEAR_VERSION (delivery-service: $OCM_GEAR_DS_VERSION)"

BOOTSTRAPPING_CHART=$(echo "${DS_COMPONENT_DESCRIPTORS}" | yq eval '.component.resources.[] | select(.name == "bootstrapping" and .type | test("helmChart")) | .access.imageReference')
DELIVERY_SERVICE_CHART=$(echo "${DS_COMPONENT_DESCRIPTORS}" | yq eval '.component.resources.[] | select(.name == "delivery-service" and .type | test("helmChart")) | .access.imageReference')
DELIVERY_DASHBOARD_CHART=$(echo "${COMPONENT_DESCRIPTORS}" | yq eval '.component.resources.[] | select(.name == "delivery-dashboard" and .type | test("helmChart")) | .access.imageReference')
EXTENSIONS_CHART=$(echo "${DS_COMPONENT_DESCRIPTORS}" | yq eval '.component.resources.[] | select(.name == "extensions" and .type | test("helmChart")) | .access.imageReference')
DELIVERY_DATABASE_CHART=$(echo "${COMPONENT_DESCRIPTORS}" | yq eval '.component.resources.[] | select(.name == "postgresql" and .type | test("helmChart")) | .access.imageReference')

echo ">>> Installing Gateway API CRDs and Envoy Gateway"
ENVOY_GATEWAY_VERSION="1.3.2"
helm upgrade -i envoy-gateway oci://docker.io/envoyproxy/gateway-helm \
    --version ${ENVOY_GATEWAY_VERSION} \
    --namespace envoy-gateway-system \
    --create-namespace \
    --wait
# Create a Gateway resource that the delivery-service and delivery-dashboard HTTPRoutes reference
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: open-delivery-gear
  namespace: ${NAMESPACE}
spec:
  gatewayClassName: eg
  listeners:
    - name: http
      protocol: HTTP
      port: 80
EOF

echo ">>> Installing bootstrapping chart from ${BOOTSTRAPPING_CHART}"
helm upgrade -i bootstrapping oci://${BOOTSTRAPPING_CHART%:*} \
  --namespace ${NAMESPACE} \
  --version ${BOOTSTRAPPING_CHART#*:} \
  --values ${CHART}/values-bootstrapping.yaml

echo ">>> Installing delivery-database from ${DELIVERY_DATABASE_CHART}"
# First, install custom pv and pvc to allow re-usage of host's filesystem mount
kubectl apply -f "${CHART}/delivery-db-pv" --namespace $NAMESPACE
helm upgrade -i delivery-db oci://${DELIVERY_DATABASE_CHART%:*} \
    --namespace $NAMESPACE \
    --version ${DELIVERY_DATABASE_CHART#*:} \
    --values ${CHART}/values-delivery-db.yaml

echo ">>> Installing delivery-service from ${DELIVERY_SERVICE_CHART}"
helm upgrade -i delivery-service oci://${DELIVERY_SERVICE_CHART%:*} \
    --namespace $NAMESPACE \
    --version ${DELIVERY_SERVICE_CHART#*:} \
    --values ${CHART}/values-delivery-service.yaml
echo "Waiting for delivery-service to become ready, this can take up to 3 minutes..."
kubectl rollout status deployment delivery-service \
    --namespace $NAMESPACE \
    --timeout=180s

echo ">>> Installing delivery-dashboard from ${DELIVERY_DASHBOARD_CHART}"
helm upgrade -i delivery-dashboard oci://${DELIVERY_DASHBOARD_CHART%:*} \
    --namespace $NAMESPACE \
    --version ${DELIVERY_DASHBOARD_CHART#*:} \
    --values ${CHART}/values-delivery-dashboard.yaml

echo ">>> Installing extensions from ${EXTENSIONS_CHART}"
helm upgrade -i extensions oci://${EXTENSIONS_CHART%:*} \
    --namespace $NAMESPACE \
    --version ${EXTENSIONS_CHART#*:} \
    --values ${CHART}/values-extensions.yaml

kubectl port-forward service/delivery-service 5000:8080 > /dev/null &
