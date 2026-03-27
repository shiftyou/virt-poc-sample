#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../env.conf"

echo "[INFO] SNR 설정 적용 중..."
oc apply -f "${SCRIPT_DIR}/snr-config.yaml"

echo "[INFO] SNR 상태 확인..."
oc get selfnoderemediationconfig -n openshift-workload-availability
oc get selfnoderemediationtemplate -n openshift-workload-availability
