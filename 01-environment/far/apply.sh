#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../env.conf"

echo "[INFO] FAR Template 적용 중..."
envsubst < "${SCRIPT_DIR}/far-config.yaml" | oc apply -f -

echo "[INFO] FAR Template 상태 확인..."
oc get fenceagentsremediationtemplate -n openshift-workload-availability
