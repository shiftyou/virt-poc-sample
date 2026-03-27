#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../env.conf"

echo "[INFO] Resource Limits 테스트 환경 생성 중..."
oc apply -f "${SCRIPT_DIR}/namespace.yaml"
oc apply -f "${SCRIPT_DIR}/limitrange.yaml"
oc apply -f "${SCRIPT_DIR}/resourcequota.yaml"

echo "[INFO] 상태 확인..."
oc get limitrange,resourcequota -n poc-resource-limits
