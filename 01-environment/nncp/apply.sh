#!/bin/bash
# NNCP 적용 스크립트
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../env.conf"

echo "[INFO] NNCP 적용 중... (BRIDGE_NAME=${BRIDGE_NAME}, BRIDGE_INTERFACE=${BRIDGE_INTERFACE})"
envsubst < "${SCRIPT_DIR}/nncp-bridge.yaml" | oc apply -f -

echo "[INFO] NNCP 상태 확인 중 (완료까지 1-2분 소요)..."
sleep 5
oc get nncp poc-bridge-nncp
