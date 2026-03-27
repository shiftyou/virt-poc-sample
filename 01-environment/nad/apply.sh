#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../env.conf"

echo "[INFO] NAD 적용 중... (BRIDGE_NAME=${BRIDGE_NAME}, NAD_NAMESPACE=${NAD_NAMESPACE})"
envsubst < "${SCRIPT_DIR}/nad-bridge.yaml" | oc apply -f -

echo "[INFO] NAD 상태 확인..."
oc get network-attachment-definitions -n "${NAD_NAMESPACE}"
