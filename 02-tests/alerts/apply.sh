#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../env.conf"

echo "[INFO] Alert 규칙 생성 중..."
oc apply -f "${SCRIPT_DIR}/namespace.yaml"
oc apply -f "${SCRIPT_DIR}/prometheusrule.yaml"

echo "[INFO] PrometheusRule 상태 확인..."
oc get prometheusrule -n poc-alerts
