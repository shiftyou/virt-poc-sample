#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../env.conf"

echo "[WARN] Console 접근 IP 제한 설정을 적용합니다."
echo "       허용 CIDR: ${CONSOLE_ALLOWED_CIDRS}"
echo ""
echo "현재 접속 IP를 확인하세요:"
curl -s ifconfig.me 2>/dev/null || echo "(확인 불가)"
echo ""
echo -n "계속 진행하시겠습니까? (y/N): "
read confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "취소되었습니다."
    exit 0
fi

# 쉼표를 공백으로 변환 (HAProxy whitelist 형식)
export CONSOLE_ALLOWED_CIDRS_SPACE=$(echo "$CONSOLE_ALLOWED_CIDRS" | tr ',' ' ')

echo "[INFO] Console Route IP 제한 적용 중..."
envsubst < "${SCRIPT_DIR}/apiserverconfig.yaml" | oc apply -f -

echo "[INFO] Console Pod 상태 확인..."
oc get pods -n openshift-console
echo ""
echo "[OK] IP 제한 설정 완료"
echo "  허용된 CIDR: ${CONSOLE_ALLOWED_CIDRS}"
