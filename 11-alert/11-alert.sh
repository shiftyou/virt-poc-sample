#!/bin/bash
# =============================================================================
# 11-alert.sh
#
# VM Alert 실습 환경 구성
#   1. poc-alert 네임스페이스 생성
#   2. User-defined project monitoring 활성화
#   3. PrometheusRule (VM 알림 규칙) 배포
#
# 사용법: ./11-alert.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

NS="poc-alert"

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

step_user_workload_monitoring() {
    print_step "2/3  User-defined Project Monitoring 활성화"

    local current
    current=$(oc get configmap cluster-monitoring-config \
        -n openshift-monitoring \
        -o jsonpath='{.data.config\.yaml}' 2>/dev/null || true)

    if echo "$current" | grep -q "enableUserWorkload: true"; then
        print_ok "User Workload Monitoring 이미 활성화됨 — 스킵"
        return
    fi

    cat > cluster-monitoring-config.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
EOF
    oc apply -f cluster-monitoring-config.yaml
    print_ok "User Workload Monitoring 활성화 완료"

    # Pod 기동 대기
    print_info "openshift-user-workload-monitoring Pod 기동 대기 중..."
    local retries=18
    local i=0
    while [ $i -lt $retries ]; do
        local ready
        ready=$(oc get pods -n openshift-user-workload-monitoring \
            --no-headers 2>/dev/null | grep -c "Running" || true)
        if [ "$ready" -ge 2 ]; then
            print_ok "User Workload Monitoring Pod 준비 완료 (${ready}개 Running)"
            break
        fi
        printf "  [%d/%d] 대기 중... (%s개 Running)\r" "$((i+1))" "$retries" "$ready"
        sleep 10
        i=$((i+1))
    done
    echo ""
}

step_prometheus_rule() {
    print_step "3/3  PrometheusRule 배포 (VM 알림 규칙)"

    cat > poc-vm-alerts.yaml <<EOF
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: poc-vm-alerts
  namespace: ${NS}
  labels:
    role: alert-rules
spec:
  groups:
    - name: poc-vm-availability
      interval: 30s
      rules:
        - alert: VMNotRunning
          expr: |
            kubevirt_vmi_phase_count{phase=~"Failed|Unknown"} > 0
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "VM이 비정상 상태입니다"
            description: "네임스페이스 {{ \$labels.namespace }}에서 {{ \$labels.phase }} 상태의 VM이 {{ \$value }}개 감지되었습니다."
        - alert: VMStuckPending
          expr: |
            kubevirt_vmi_phase_count{phase="Pending"} > 0
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "VM이 Pending 상태로 대기 중입니다"
            description: "네임스페이스 {{ \$labels.namespace }}에서 Pending 상태의 VM이 {{ \$value }}개 있습니다."
        - alert: VMLiveMigrationFailed
          expr: |
            increase(kubevirt_vmi_migration_phase_transition_time_seconds_count{phase="Failed"}[10m]) > 0
          labels:
            severity: warning
          annotations:
            summary: "VM Live Migration이 실패했습니다"
            description: "VM {{ \$labels.vmi }}의 Live Migration이 실패했습니다."
    - name: poc-vm-resources
      interval: 60s
      rules:
        - alert: VMLowMemory
          expr: |
            kubevirt_vmi_memory_available_bytes < 100 * 1024 * 1024
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "VM 메모리가 부족합니다"
            description: "VM {{ \$labels.name }} (네임스페이스: {{ \$labels.namespace }})의 사용 가능 메모리가 {{ \$value | humanize }}입니다."
EOF
    oc apply -f poc-vm-alerts.yaml
    print_ok "PrometheusRule poc-vm-alerts 배포 완료"
}

print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  완료! VM Alert 실습 환경이 준비되었습니다.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  PrometheusRule 확인:"
    echo -e "    ${CYAN}oc get prometheusrule -n ${NS}${NC}"
    echo ""
    echo -e "  Alert 상태 확인:"
    echo -e "    ${CYAN}OpenShift Console → Observe → Alerting → Alert Rules${NC}"
    echo ""
    echo -e "  자세한 내용: 11-alert.md 참조"
    echo ""
}

main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  VM Alert 실습 환경 구성${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    preflight
    step_namespace
    step_user_workload_monitoring
    step_prometheus_rule
    print_summary
}

main
