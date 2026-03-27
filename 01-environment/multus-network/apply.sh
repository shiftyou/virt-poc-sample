#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../env.conf"

echo "[INFO] Multus 멀티 네트워크 테스트 환경 생성 중..."
oc apply -f "${SCRIPT_DIR}/namespace.yaml"
envsubst < "${SCRIPT_DIR}/test-vm-multus.yaml" | oc apply -f -

echo ""
echo "다음 단계:"
echo "  VM 시작: oc patch vm test-multus-vm -n poc-multus --type merge -p '{\"spec\":{\"running\":true}}'"
echo "  네트워크 확인: oc get vmi test-multus-vm -n poc-multus -o jsonpath='{.status.interfaces}'"
