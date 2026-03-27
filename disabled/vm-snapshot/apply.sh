#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../env.conf"

echo "[INFO] VM 스냅샷 테스트 환경 생성 중..."
oc apply -f "${SCRIPT_DIR}/namespace.yaml"
oc apply -f "${SCRIPT_DIR}/test-vm.yaml"

echo ""
echo "다음 단계:"
echo "  1. VM 시작:"
echo "     oc patch vm test-snapshot-vm -n poc-vm-snapshot --type merge -p '{\"spec\":{\"running\":true}}'"
echo "  2. 스냅샷 생성:"
echo "     oc apply -f ${SCRIPT_DIR}/vm-snapshot.yaml"
echo "  3. 스냅샷 상태 확인:"
echo "     oc get vmsnapshot -n poc-vm-snapshot"
echo "  4. VM 중지 후 복원:"
echo "     oc patch vm test-snapshot-vm -n poc-vm-snapshot --type merge -p '{\"spec\":{\"running\":false}}'"
echo "     oc apply -f ${SCRIPT_DIR}/vm-restore.yaml"
