#!/bin/bash
# =============================================================================
# 12-node-exporter.sh
#
# 커스텀 Node Exporter 실습 환경 구성
#   1. poc-node-exporter 네임스페이스 생성
#   2. ServiceAccount + SCC 설정
#   3. DaemonSet 배포
#   4. Service + ServiceMonitor 등록
#
# 사용법: ./12-node-exporter.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

NS="poc-node-exporter"

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

    # 내장 node-exporter 확인
    local builtin_count
    builtin_count=$(oc get pods -n openshift-monitoring \
        -l app.kubernetes.io/name=node-exporter \
        --no-headers 2>/dev/null | wc -l | tr -d ' ')
    print_info "내장 node-exporter Pod: ${builtin_count}개 (openshift-monitoring)"
}

step_namespace() {
    print_step "1/4  네임스페이스 생성 (${NS})"

    if oc get namespace "$NS" &>/dev/null; then
        print_ok "네임스페이스 $NS 이미 존재 — 스킵"
    else
        oc new-project "$NS" > /dev/null
        print_ok "네임스페이스 $NS 생성 완료"
    fi
}

step_serviceaccount() {
    print_step "2/4  ServiceAccount + SCC 설정"

    if ! oc get sa node-exporter-sa -n "$NS" &>/dev/null; then
        oc create serviceaccount node-exporter-sa -n "$NS"
        print_ok "ServiceAccount node-exporter-sa 생성 완료"
    else
        print_ok "ServiceAccount 이미 존재 — 스킵"
    fi

    oc adm policy add-scc-to-user privileged \
        -z node-exporter-sa -n "$NS" 2>/dev/null || true
    print_ok "privileged SCC 부여 완료"
}

step_daemonset() {
    print_step "3/4  Node Exporter DaemonSet 배포"

    cat > custom-node-exporter-ds.yaml <<'EOF'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: custom-node-exporter
  labels:
    app: custom-node-exporter
spec:
  selector:
    matchLabels:
      app: custom-node-exporter
  template:
    metadata:
      labels:
        app: custom-node-exporter
    spec:
      serviceAccountName: node-exporter-sa
      hostNetwork: true
      hostPID: true
      tolerations:
        - operator: Exists
      containers:
        - name: node-exporter
          image: quay.io/prometheus/node-exporter:latest
          args:
            - "--path.rootfs=/host"
            - "--collector.filesystem.mount-points-exclude=^/(dev|proc|sys|run/k8s.io/.+)($|/)"
          ports:
            - name: metrics
              containerPort: 9100
              hostPort: 9100
          securityContext:
            privileged: true
            runAsUser: 0
          volumeMounts:
            - name: host-root
              mountPath: /host
              readOnly: true
      volumes:
        - name: host-root
          hostPath:
            path: /
EOF
    oc apply -n "$NS" -f custom-node-exporter-ds.yaml
    print_ok "DaemonSet custom-node-exporter 배포 완료"
}

step_service_monitor() {
    print_step "4/4  Service + ServiceMonitor 등록"

    cat > custom-node-exporter-svc.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: custom-node-exporter
  labels:
    app: custom-node-exporter
spec:
  ports:
    - name: metrics
      port: 9100
      targetPort: 9100
  selector:
    app: custom-node-exporter
  clusterIP: None
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: custom-node-exporter
  labels:
    app: custom-node-exporter
spec:
  selector:
    matchLabels:
      app: custom-node-exporter
  endpoints:
    - port: metrics
      interval: 30s
      path: /metrics
EOF
    oc apply -n "$NS" -f custom-node-exporter-svc.yaml
    print_ok "Service + ServiceMonitor 등록 완료"
}

print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  완료! Node Exporter 실습 환경이 준비되었습니다.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  DaemonSet 상태 확인:"
    echo -e "    ${CYAN}oc get daemonset custom-node-exporter -n ${NS}${NC}"
    echo ""
    echo -e "  메트릭 접근 (port-forward):"
    echo -e "    ${CYAN}oc port-forward -n ${NS} daemonset/custom-node-exporter 9100:9100${NC}"
    echo -e "    ${CYAN}curl http://localhost:9100/metrics | grep node_memory${NC}"
    echo ""
    echo -e "  내장 node-exporter 메트릭:"
    echo -e "    OpenShift Console → Observe → Metrics"
    echo -e "    쿼리: node_memory_MemAvailable_bytes"
    echo ""
    echo -e "  자세한 내용: 12-node-exporter.md 참조"
    echo ""
}

main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Node Exporter 실습 환경 구성${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    preflight
    step_namespace
    step_serviceaccount
    step_daemonset
    step_service_monitor
    print_summary
}

main
