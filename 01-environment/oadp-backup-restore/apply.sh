#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../env.conf"

echo "[INFO] OADP 백업/복원 테스트 환경 생성 중..."

# BackupStorageLocation 상태 확인
BSL_STATUS=$(oc get backupstoragelocation -n openshift-adp \
    -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
if [ "$BSL_STATUS" != "Available" ]; then
    echo "[WARN] BackupStorageLocation이 Available 상태가 아닙니다: ${BSL_STATUS}"
    echo "       01-environment/oadp/apply.sh를 먼저 실행하세요."
fi

oc apply -f "${SCRIPT_DIR}/namespace.yaml"
oc apply -f "${SCRIPT_DIR}/test-vm.yaml"

echo "[INFO] 테스트 VM 생성 완료"
echo ""
echo "다음 단계:"
echo "  1. VM 시작:"
echo "     oc patch vm test-backup-vm -n poc-oadp-test --type merge -p '{\"spec\":{\"running\":true}}'"
echo "  2. VM 준비 후 백업:"
echo "     oc apply -f ${SCRIPT_DIR}/backup.yaml"
echo "  3. 백업 완료 확인:"
echo "     oc get backup test-vm-backup -n openshift-adp"
echo "  4. VM 삭제 후 복원:"
echo "     oc delete vm test-backup-vm -n poc-oadp-test"
echo "     oc apply -f ${SCRIPT_DIR}/restore.yaml"
