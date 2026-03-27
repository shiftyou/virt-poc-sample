#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../env.conf"

# MinIO Route에서 엔드포인트 자동 감지
MINIO_ROUTE=$(oc get route minio -n poc-minio -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -n "$MINIO_ROUTE" ]; then
    export MINIO_ENDPOINT="https://${MINIO_ROUTE}"
    echo "[INFO] MinIO 엔드포인트: ${MINIO_ENDPOINT}"
else
    echo "[INFO] MinIO Route 없음. env.conf의 MINIO_ENDPOINT 사용: ${MINIO_ENDPOINT}"
fi

echo "[INFO] OADP DPA 적용 중..."
envsubst < "${SCRIPT_DIR}/oadp-dpa.yaml" | oc apply -f -

echo "[INFO] BackupStorageLocation 상태 확인 (최대 2분 대기)..."
for i in $(seq 1 12); do
    STATUS=$(oc get backupstoragelocation -n openshift-adp \
        -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
    if [ "$STATUS" = "Available" ]; then
        echo "[OK] BackupStorageLocation 준비 완료!"
        break
    fi
    echo "  대기 중... ($i/12)"
    sleep 10
done

oc get dataprotectionapplication -n openshift-adp
oc get backupstoragelocation -n openshift-adp
