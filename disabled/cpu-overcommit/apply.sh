#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../env.conf"

echo "[INFO] CPU Overcommit 설정 적용 중..."
echo "[WARN] 이 설정은 클러스터 전체에 영향을 미칩니다."
echo -n "계속 진행하시겠습니까? (y/N): "
read confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "취소되었습니다."
    exit 0
fi

oc apply -f "${SCRIPT_DIR}/namespace.yaml"
oc apply -f "${SCRIPT_DIR}/kubevirt-config.yaml"

echo "[INFO] KubeVirt 설정 확인..."
oc get kubevirt kubevirt -n openshift-cnv \
  -o jsonpath='{.spec.configuration.developerConfiguration}' | python3 -m json.tool 2>/dev/null || \
  oc get kubevirt kubevirt -n openshift-cnv -o yaml | grep -A5 "developerConfiguration"
