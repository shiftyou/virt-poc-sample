#!/bin/bash
# MinIO 배포 스크립트
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../env.conf"

echo "[INFO] MinIO 배포 중..."
envsubst < "${SCRIPT_DIR}/minio-deploy.yaml" | oc apply -f -
oc apply -f "${SCRIPT_DIR}/minio-service.yaml"
oc apply -f "${SCRIPT_DIR}/minio-route.yaml"

echo "[INFO] MinIO Pod 준비 대기 중..."
oc rollout status deployment/minio -n poc-minio --timeout=120s

echo "[INFO] MinIO 접근 정보:"
MINIO_CONSOLE_ROUTE=$(oc get route minio-console -n poc-minio -o jsonpath='{.spec.host}' 2>/dev/null || echo "대기 중")
MINIO_API_ROUTE=$(oc get route minio -n poc-minio -o jsonpath='{.spec.host}' 2>/dev/null || echo "대기 중")
echo "  S3 API: https://${MINIO_API_ROUTE}"
echo "  Console: https://${MINIO_CONSOLE_ROUTE}"
echo "  Access Key: ${MINIO_ACCESS_KEY}"
echo ""
echo "[INFO] 다음 단계: 버킷 생성"
echo "  mc alias set local https://${MINIO_API_ROUTE} ${MINIO_ACCESS_KEY} ${MINIO_SECRET_KEY} --insecure"
echo "  mc mb local/${MINIO_BUCKET} --insecure"
