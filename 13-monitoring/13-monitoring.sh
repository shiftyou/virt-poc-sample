#!/bin/bash
# =============================================================================
# 13-monitoring.sh
#
# 모니터링 실습 환경 구성 (Grafana + 스토리지 모니터링)
#   1. poc-monitoring 네임스페이스 생성
#   2. Grafana 인스턴스 배포 (Grafana Operator 필요)
#   3. Prometheus DataSource 연동
#
# 사용법: ./13-monitoring.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

NS="poc-monitoring"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

print_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
print_ok()    { echo -e "${GREEN}[ OK ]${NC} $1"; }
print_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERR ]${NC} $1"; }
print_step()  { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }

preflight() {
    print_step "사전 확인"

    if ! oc whoami &>/dev/null; then
        print_error "OpenShift 에 로그인되어 있지 않습니다."
        exit 1
    fi
    print_ok "클러스터 접속: $(oc whoami) @ $(oc whoami --show-server)"

    if [ "${GRAFANA_INSTALLED:-false}" != "true" ]; then
        print_warn "Grafana Operator 미설치 → 건너뜁니다."
        print_warn "  설치 가이드: 00-operator/grafana-operator.md"
        exit 77
    fi
    print_ok "Grafana Operator 확인"
}

step_namespace() {
    print_step "1/3  네임스페이스 생성 (${NS})"

    if oc get namespace "$NS" &>/dev/null; then
        print_ok "네임스페이스 $NS 이미 존재 — 스킵"
    else
        oc new-project "$NS" > /dev/null
        print_ok "네임스페이스 $NS 생성 완료"
    fi
}

step_grafana() {
    print_step "2/3  Grafana 인스턴스 배포"

    if oc get grafana poc-grafana -n "$NS" &>/dev/null; then
        print_ok "Grafana poc-grafana 이미 존재 — 스킵"
    else
        cat > poc-grafana.yaml <<EOF
apiVersion: grafana.integreatly.org/v1beta1
kind: Grafana
metadata:
  name: poc-grafana
  namespace: ${NS}
  labels:
    dashboards: poc-grafana
spec:
  config:
    auth:
      disable_login_form: "false"
    auth.anonymous:
      enabled: "false"
    security:
      admin_user: admin
      admin_password: ${GRAFANA_ADMIN_PASS:-grafana123}
  ingress:
    enabled: true
EOF
        oc apply -f poc-grafana.yaml
        print_ok "Grafana poc-grafana 배포 완료"
    fi

    # Grafana SA에 cluster-monitoring-view 권한 부여
    print_info "Prometheus 접근 권한 설정 중..."
    local retries=12
    local i=0
    while [ $i -lt $retries ]; do
        if oc get sa poc-grafana-sa -n "$NS" &>/dev/null; then
            break
        fi
        printf "  [%d/%d] Grafana SA 생성 대기 중...\r" "$((i+1))" "$retries"
        sleep 5
        i=$((i+1))
    done
    echo ""

    oc create clusterrolebinding grafana-cluster-monitoring-view \
        --clusterrole=cluster-monitoring-view \
        --serviceaccount="${NS}:poc-grafana-sa" 2>/dev/null || \
        print_info "ClusterRoleBinding 이미 존재"
    print_ok "cluster-monitoring-view 권한 부여 완료"
}

step_datasource() {
    print_step "3/3  Prometheus DataSource 연동"

    # ServiceAccount 토큰 생성
    TOKEN=$(oc create token poc-grafana-sa -n "$NS" --duration=8760h 2>/dev/null || true)
    if [ -z "$TOKEN" ]; then
        print_warn "Grafana SA 토큰 생성 실패 — Grafana Pod가 아직 준비 중일 수 있습니다."
        print_info "수동으로 실행: oc create token poc-grafana-sa -n ${NS} --duration=8760h"
        return
    fi

    cat > prometheus-datasource.yaml <<EOF
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: prometheus-datasource
  namespace: ${NS}
spec:
  instanceSelector:
    matchLabels:
      dashboards: poc-grafana
  datasource:
    name: Prometheus
    type: prometheus
    access: proxy
    url: https://thanos-querier.openshift-monitoring.svc.cluster.local:9091
    isDefault: true
    jsonData:
      httpHeaderName1: Authorization
      timeInterval: 5s
      tlsSkipVerify: true
    secureJsonData:
      httpHeaderValue1: Bearer ${TOKEN}
EOF
    oc apply -f prometheus-datasource.yaml
    print_ok "Prometheus DataSource 연동 완료"
}

print_summary() {
    local route
    route=$(oc get route -n "$NS" -l app=grafana \
        -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  완료! 모니터링 실습 환경이 준비되었습니다.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    if [ -n "$route" ]; then
        echo -e "  Grafana URL: ${CYAN}https://${route}${NC}"
        echo -e "  계정: admin / ${GRAFANA_ADMIN_PASS:-grafana123}"
    else
        echo -e "  Grafana Route 확인: ${CYAN}oc get route -n ${NS}${NC}"
    fi
    echo ""
    echo -e "  Pod 상태 확인:"
    echo -e "    ${CYAN}oc get pods -n ${NS}${NC}"
    echo ""
    echo -e "  자세한 내용: 13-monitoring.md 참조"
    echo ""
}

main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  모니터링 실습 환경 구성${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    preflight
    step_namespace
    step_grafana
    step_datasource
    print_summary
}

main
