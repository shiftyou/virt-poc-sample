#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../env.conf"

echo "[INFO] VM 라이브 마이그레이션 테스트 환경 생성 중..."
oc apply -f "${SCRIPT_DIR}/namespace.yaml"
oc apply -f "${SCRIPT_DIR}/test-vm.yaml"
oc apply -f "${SCRIPT_DIR}/migration-policy.yaml"

echo ""
echo "다음 단계:"
echo "  1. VM 시작:"
echo "     oc patch vm test-migration-vm -n poc-live-migration --type merge -p '{\"spec\":{\"running\":true}}'"
echo "  2. VM 준비 확인 (Running 상태):"
echo "     oc get vmi -n poc-live-migration"
echo "  3. 마이그레이션 실행:"
echo "     oc apply -f ${SCRIPT_DIR}/consoleYamlSample.yaml"
echo "  4. 마이그레이션 상태 확인:"
echo "     oc get vmim -n poc-live-migration -w"
