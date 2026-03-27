#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../env.conf"

echo "[INFO] Descheduler 설정 적용 중..."
oc apply -f "${SCRIPT_DIR}/namespace.yaml"
oc apply -f "${SCRIPT_DIR}/kubedescheduler.yaml"

echo "[INFO] Descheduler 상태 확인..."
oc get kubedescheduler -n openshift-kube-descheduler-operator
