#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../env.conf"

echo "[INFO] Grafana 배포 중..."
envsubst < "${SCRIPT_DIR}/grafana-deploy.yaml" | oc apply -f -

echo "[INFO] Prometheus 접근 권한 부여 중..."
oc adm policy add-cluster-role-to-user cluster-monitoring-view \
  -z grafana-serviceaccount -n poc-grafana

# ServiceAccount 토큰을 datasource ConfigMap에 주입
SA_TOKEN=$(oc serviceaccounts get-token grafana-serviceaccount -n poc-grafana 2>/dev/null || echo "")
if [ -n "$SA_TOKEN" ]; then
    sed "s|<REPLACE_WITH_SA_TOKEN>|${SA_TOKEN}|g" \
        "${SCRIPT_DIR}/grafana-datasource.yaml" | oc apply -f -
    echo "[OK] Prometheus datasource 설정 완료"
else
    echo "[WARN] SA 토큰을 가져올 수 없습니다. datasource.yaml을 수동으로 수정하세요."
    oc apply -f "${SCRIPT_DIR}/grafana-datasource.yaml"
fi

oc apply -f "${SCRIPT_DIR}/grafana-dashboard-cm.yaml"

echo "[INFO] Grafana Pod 준비 대기 중..."
oc rollout status deployment/grafana -n poc-grafana --timeout=120s

GRAFANA_URL=$(oc get route grafana -n poc-grafana -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
echo ""
echo "[OK] Grafana 배포 완료!"
echo "  URL: https://${GRAFANA_URL}"
echo "  Username: admin"
echo "  Password: ${GRAFANA_ADMIN_PASS}"
