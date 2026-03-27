#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../env.conf"

echo "[INFO] Storage DataVolume 테스트 환경 생성 중..."
oc apply -f "${SCRIPT_DIR}/namespace.yaml"
oc apply -f "${SCRIPT_DIR}/storageprofile-patch.yaml"
oc apply -f "${SCRIPT_DIR}/datavolume.yaml"

echo "[INFO] DataVolume 상태 확인..."
oc get datavolume -n poc-storage-dv
echo ""
echo "DataVolume 임포트 완료 대기:"
echo "  oc get datavolume -n poc-storage-dv -w"
