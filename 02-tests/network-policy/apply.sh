#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../env.conf"

echo "[INFO] Network Policy 테스트 환경 생성 중..."
oc apply -f "${SCRIPT_DIR}/namespace.yaml"
oc apply -f "${SCRIPT_DIR}/networkpolicy-deny-all.yaml"
oc apply -f "${SCRIPT_DIR}/networkpolicy-allow-same-ns.yaml"
oc apply -f "${SCRIPT_DIR}/networkpolicy-allow-ingress.yaml"

echo "[INFO] NetworkPolicy 상태 확인..."
oc get networkpolicy -n poc-netpol
