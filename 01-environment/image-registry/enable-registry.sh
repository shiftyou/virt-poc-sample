#!/bin/bash
# =============================================================================
# OpenShift 내부 이미지 레지스트리 활성화 스크립트
#
# 사용법: ./enable-registry.sh
# =============================================================================

set -euo pipefail

echo "[INFO] OpenShift 내부 이미지 레지스트리 활성화 중..."

# 현재 상태 확인
CURRENT_STATE=$(oc get configs.imageregistry.operator.openshift.io cluster \
    -o jsonpath='{.spec.managementState}' 2>/dev/null || echo "Unknown")
echo "[INFO] 현재 레지스트리 상태: $CURRENT_STATE"

# managementState를 Managed로 변경하고 PVC 스토리지 설정
oc patch configs.imageregistry.operator.openshift.io cluster \
    --type=merge \
    --patch='
{
  "spec": {
    "managementState": "Managed",
    "storage": {
      "pvc": {
        "claim": ""
      }
    },
    "replicas": 1
  }
}'

echo "[INFO] 레지스트리 설정 변경 완료. Pod 재시작 대기 중..."

# Pod 준비 완료 대기 (최대 5분)
oc rollout status deployment/image-registry -n openshift-image-registry --timeout=300s

echo "[OK] 내부 이미지 레지스트리 활성화 완료!"
echo ""

# 외부 접근을 위한 Route 생성 (선택사항)
echo "[INFO] 외부 접근용 Route 생성 중..."
oc patch configs.imageregistry.operator.openshift.io cluster \
    --type=merge \
    --patch='{"spec":{"defaultRoute":true}}'

REGISTRY_ROUTE=$(oc get route default-route -n openshift-image-registry \
    -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -n "$REGISTRY_ROUTE" ]; then
    echo "[OK] 레지스트리 외부 접근 주소: https://${REGISTRY_ROUTE}"
fi

echo ""
echo "  내부 레지스트리 주소: image-registry.openshift-image-registry.svc:5000"
echo "  이미지 push 예시:"
echo "  podman push <image> image-registry.openshift-image-registry.svc:5000/openshift/<name>:latest"
