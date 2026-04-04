#!/bin/bash
# =============================================================================
# 11-monitoring.sh
#
# 모니터링 실습 환경 구성 (Grafana + Cluster Observability Operator)
#   1. poc-monitoring 네임스페이스 생성
#   2. Grafana 인스턴스 배포 (Grafana Operator 필요)
#   3. Prometheus DataSource 연동
#   4. poc 템플릿 VM + node-exporter Service 배포 (COO + Virt 필요)
#   5. COO MonitoringStack + ServiceMonitor + PrometheusRule 배포 (COO 필요)
#
# 사용법: ./11-monitoring.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

NS="poc-monitoring"
VM_NAME="poc-monitoring-vm"

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

step_install_grafana_guide() {
    echo ""
    print_warn "Grafana 커뮤니티 Operator 미설치 — 아래 절차로 설치 후 setup.sh 재실행하세요."
    echo ""
    echo -e "  ${CYAN}# 1. Grafana Operator (커뮤니티) 설치 — poc-monitoring 네임스페이스 범위${NC}"
    echo -e "  ${CYAN}oc apply -f - <<'EOF'${NC}"
    cat <<'YAML'
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: grafana-operator-group
  namespace: poc-monitoring
spec:
  targetNamespaces:
    - poc-monitoring
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: grafana-operator
  namespace: poc-monitoring
spec:
  channel: v5
  name: grafana-operator
  source: community-operators
  sourceNamespace: openshift-marketplace
YAML
    echo -e "  ${CYAN}EOF${NC}"
    echo ""
    print_info "설치 완료 후 확인:"
    echo -e "  ${CYAN}oc get csv -n poc-monitoring | grep grafana${NC}"
    print_info "설치 완료 후 setup.sh 재실행하여 GRAFANA_INSTALLED=true 로 업데이트하세요."
    echo ""
}

preflight() {
    print_step "사전 확인"

    if ! oc whoami &>/dev/null; then
        print_error "OpenShift 에 로그인되어 있지 않습니다."
        exit 1
    fi
    print_ok "클러스터 접속: $(oc whoami) @ $(oc whoami --show-server)"

    if [ "${GRAFANA_INSTALLED:-false}" != "true" ] && [ "${COO_INSTALLED:-false}" != "true" ]; then
        print_warn "Grafana Operator 및 Cluster Observability Operator 모두 미설치 → 건너뜁니다."
        step_install_grafana_guide
        print_warn "  COO 설치 가이드: 00-operator/coo-operator.md"
        exit 77
    fi

    if [ "${GRAFANA_INSTALLED:-false}" = "true" ]; then
        print_ok "Grafana 커뮤니티 Operator 확인"
    else
        print_warn "Grafana Operator 미설치 — Grafana 스텝 건너뜁니다."
        step_install_grafana_guide
    fi

    if [ "${COO_INSTALLED:-false}" = "true" ]; then
        print_ok "Cluster Observability Operator 확인"
        if [ "${VIRT_INSTALLED:-false}" = "true" ]; then
            print_ok "OpenShift Virtualization 확인 — VM 생성 스텝 실행됩니다."
        else
            print_warn "OpenShift Virtualization 미설치 — VM 생성 스텝 건너뜁니다."
        fi
    else
        print_warn "Cluster Observability Operator 미설치 — COO 스텝 건너뜁니다."
    fi
}

step_namespace() {
    print_step "1/5  네임스페이스 생성 (${NS})"

    if oc get namespace "$NS" &>/dev/null; then
        print_ok "네임스페이스 $NS 이미 존재 — 스킵"
    else
        oc new-project "$NS" > /dev/null
        print_ok "네임스페이스 $NS 생성 완료"
    fi
}

step_grafana() {
    if [ "${GRAFANA_INSTALLED:-false}" != "true" ]; then
        return
    fi
    print_step "2/5  Grafana 인스턴스 배포"

    if oc get grafana poc-grafana -n "$NS" &>/dev/null; then
        print_ok "Grafana poc-grafana 이미 존재 — 스킵"
    else
        cat > /tmp/poc-grafana.yaml <<EOF
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
        oc apply -f /tmp/poc-grafana.yaml
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
    if [ "${GRAFANA_INSTALLED:-false}" != "true" ]; then
        return
    fi
    print_step "3/5  Prometheus DataSource 연동"

    # ServiceAccount 토큰 생성
    TOKEN=$(oc create token poc-grafana-sa -n "$NS" --duration=8760h 2>/dev/null || true)
    if [ -z "$TOKEN" ]; then
        print_warn "Grafana SA 토큰 생성 실패 — Grafana Pod가 아직 준비 중일 수 있습니다."
        print_info "수동으로 실행: oc create token poc-grafana-sa -n ${NS} --duration=8760h"
        return
    fi

    cat > /tmp/prometheus-datasource.yaml <<EOF
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
    oc apply -f /tmp/prometheus-datasource.yaml
    print_ok "Prometheus DataSource 연동 완료"
}

step_vm() {
    if [ "${COO_INSTALLED:-false}" != "true" ] || [ "${VIRT_INSTALLED:-false}" != "true" ]; then
        return
    fi
    print_step "4/5  poc 템플릿 VM 생성 (${VM_NAME})"

    if ! oc get template poc -n openshift &>/dev/null; then
        print_warn "poc Template 없음 — 01-template 을 먼저 실행하세요. VM 생성 건너뜁니다."
        return
    fi
    print_ok "poc Template 확인"

    if ! command -v virtctl &>/dev/null; then
        print_warn "virtctl 없음 — VM 생성 건너뜁니다."
        return
    fi

    # VM 생성
    if oc get vm "$VM_NAME" -n "$NS" &>/dev/null; then
        print_ok "VM $VM_NAME 이미 존재 — 스킵"
    else
        oc process -n openshift poc -p NAME="$VM_NAME" > /tmp/${VM_NAME}.yaml
        oc apply -n "$NS" -f /tmp/${VM_NAME}.yaml
        print_ok "VM $VM_NAME 생성 완료"
    fi

    # virt-launcher Pod에 monitor=metrics 레이블 전파
    oc patch vm "$VM_NAME" -n "$NS" --type=merge -p '{
      "spec": {
        "template": {
          "metadata": {
            "labels": {
              "monitor": "metrics"
            }
          }
        }
      }
    }' 2>/dev/null && print_ok "레이블 monitor=metrics 설정 완료" || true

    # node-exporter Service 생성
    # virt-launcher Pod(monitor=metrics)에서 VM 내부 node-exporter(9100)로 트래픽 전달
    if oc get svc poc-monitoring-node-exporter -n "$NS" &>/dev/null; then
        print_ok "Service poc-monitoring-node-exporter 이미 존재 — 스킵"
    else
        cat > /tmp/poc-monitoring-vm-service.yaml <<EOF
apiVersion: v1
kind: Service
metadata:
  name: poc-monitoring-node-exporter
  namespace: ${NS}
  labels:
    app: poc-monitoring-vm
    monitoring.rhobs/stack: poc-monitoring-stack
spec:
  ports:
    - name: metrics
      protocol: TCP
      port: 9100
      targetPort: 9100
  selector:
    monitor: metrics
  type: ClusterIP
EOF
        oc apply -f /tmp/poc-monitoring-vm-service.yaml
        print_ok "Service poc-monitoring-node-exporter 생성 완료"
    fi

    # 네임스페이스에 user-workload 모니터링 레이블 추가 (OpenShift Console 가시성)
    oc label namespace "$NS" openshift.io/cluster-monitoring=true --overwrite 2>/dev/null || true
    print_ok "user-workload 모니터링 레이블 설정 완료"

    # OpenShift Console Observe 탭용 ServiceMonitor (monitoring.coreos.com/v1)
    if oc get servicemonitor poc-vm-node-exporter-console -n "$NS" &>/dev/null; then
        print_ok "ServiceMonitor poc-vm-node-exporter-console 이미 존재 — 스킵"
    else
        cat > /tmp/poc-vm-servicemonitor-console.yaml <<EOF
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: poc-vm-node-exporter-console
  namespace: ${NS}
  labels:
    app: poc-monitoring-vm
spec:
  selector:
    matchLabels:
      app: poc-monitoring-vm
  endpoints:
    - port: metrics
      interval: 30s
      path: /metrics
      relabelings:
        - targetLabel: job
          replacement: poc-monitoring-vm
        - sourceLabels: [__meta_kubernetes_endpoint_hostname]
          targetLabel: vmname
EOF
        oc apply -f /tmp/poc-vm-servicemonitor-console.yaml
        print_ok "ServiceMonitor poc-vm-node-exporter-console 생성 완료 (OpenShift Console 용)"
    fi

    # VM 시작
    virtctl start "$VM_NAME" -n "$NS" 2>/dev/null || true
    print_info "VM 시작 요청 완료 — Running 상태까지 시간이 걸릴 수 있습니다."
    print_warn "VM에 node_exporter 설치가 필요합니다 (09-node-exporter/node-exporter-install.sh 참조)"
    print_info "  oc get vmi $VM_NAME -n $NS"
}

step_coo() {
    if [ "${COO_INSTALLED:-false}" != "true" ]; then
        return
    fi
    print_step "5/5  Cluster Observability Operator (COO) 구성"

    # MonitoringStack CRD 확인
    if ! oc get crd monitoringstacks.monitoring.rhobs &>/dev/null; then
        print_warn "MonitoringStack CRD 없음 — COO가 완전히 설치되지 않았습니다."
        return
    fi
    print_ok "MonitoringStack CRD 확인"

    # MonitoringStack 생성
    if oc get monitoringstack poc-monitoring-stack -n "$NS" &>/dev/null; then
        print_ok "MonitoringStack poc-monitoring-stack 이미 존재 — 스킵"
    else
        cat > /tmp/poc-monitoring-stack.yaml <<EOF
apiVersion: monitoring.rhobs/v1alpha1
kind: MonitoringStack
metadata:
  name: poc-monitoring-stack
  namespace: ${NS}
spec:
  logLevel: info
  retention: 24h
  resourceSelector:
    matchLabels:
      monitoring.rhobs/stack: poc-monitoring-stack
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi
  prometheusConfig:
    replicas: 1
  alertmanagerConfig:
    enabled: true
EOF
        oc apply -f /tmp/poc-monitoring-stack.yaml
        print_ok "MonitoringStack poc-monitoring-stack 배포 완료"
    fi

    # ServiceMonitor for VM node-exporter (monitoring.rhobs/v1 — COO용)
    if [ "${VIRT_INSTALLED:-false}" = "true" ]; then
        if oc get servicemonitor.monitoring.rhobs poc-vm-node-exporter -n "$NS" &>/dev/null; then
            print_ok "ServiceMonitor poc-vm-node-exporter 이미 존재 — 스킵"
        else
            cat > /tmp/poc-vm-servicemonitor-coo.yaml <<EOF
apiVersion: monitoring.rhobs/v1
kind: ServiceMonitor
metadata:
  name: poc-vm-node-exporter
  namespace: ${NS}
  labels:
    monitoring.rhobs/stack: poc-monitoring-stack
spec:
  selector:
    matchLabels:
      app: poc-monitoring-vm
  endpoints:
    - port: metrics
      interval: 30s
      path: /metrics
      relabelings:
        - targetLabel: job
          replacement: poc-monitoring-vm
        - sourceLabels: [__meta_kubernetes_endpoint_hostname]
          targetLabel: vmname
EOF
            oc apply -f /tmp/poc-vm-servicemonitor-coo.yaml
            print_ok "ServiceMonitor poc-vm-node-exporter 생성 완료 (COO 전용)"
        fi
    fi

    # PrometheusRule (VM 알림 규칙)
    if oc get prometheusrule poc-vm-alerts -n "$NS" &>/dev/null; then
        print_ok "PrometheusRule poc-vm-alerts 이미 존재 — 스킵"
    else
        cat > /tmp/poc-vm-alerts.yaml <<EOF
apiVersion: monitoring.rhobs/v1
kind: PrometheusRule
metadata:
  name: poc-vm-alerts
  namespace: ${NS}
  labels:
    monitoring.rhobs/stack: poc-monitoring-stack
spec:
  groups:
    - name: vm.rules
      interval: 30s
      rules:
        - alert: VMNotRunning
          expr: kubevirt_vmi_phase_count{phase!="Running"} > 0
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "VM이 Running 상태가 아닙니다"
            description: "VM {{ \$labels.name }} 상태: {{ \$labels.phase }}"
        - alert: VMHighMemoryUsage
          expr: >
            (kubevirt_vmi_memory_resident_bytes /
             (kubevirt_vmi_memory_resident_bytes + kubevirt_vmi_memory_available_bytes)) > 0.9
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "VM 메모리 사용률 90% 초과"
            description: "VM {{ \$labels.name }} 의 메모리 사용률이 높습니다."
EOF
        oc apply -f /tmp/poc-vm-alerts.yaml
        print_ok "PrometheusRule poc-vm-alerts 생성 완료"
    fi

    # Grafana가 함께 설치된 경우 COO Prometheus를 추가 DataSource로 등록
    if [ "${GRAFANA_INSTALLED:-false}" = "true" ]; then
        print_info "COO Prometheus → Grafana DataSource 등록 중..."
        if oc get grafanadatasource coo-prometheus-datasource -n "$NS" &>/dev/null; then
            print_ok "GrafanaDatasource coo-prometheus-datasource 이미 존재 — 스킵"
        else
            cat > /tmp/coo-prometheus-datasource.yaml <<EOF
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: coo-prometheus-datasource
  namespace: ${NS}
spec:
  instanceSelector:
    matchLabels:
      dashboards: poc-grafana
  datasource:
    name: COO-Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus-operated.${NS}.svc.cluster.local:9090
    isDefault: false
    jsonData:
      timeInterval: 5s
EOF
            oc apply -f /tmp/coo-prometheus-datasource.yaml
            print_ok "GrafanaDatasource coo-prometheus-datasource 등록 완료"
        fi
    fi

    print_info "MonitoringStack Pod 기동 대기 중..."
    local retries=12
    local i=0
    while [ $i -lt $retries ]; do
        local ready
        ready=$(oc get pods -n "$NS" -l app.kubernetes.io/name=prometheus \
            --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
        if [ "$ready" -ge 1 ]; then
            print_ok "COO Prometheus Pod 실행 중"
            break
        fi
        printf "  [%d/%d] COO Prometheus 대기 중...\r" "$((i+1))" "$retries"
        sleep 5
        i=$((i+1))
    done
    echo ""
}

print_summary() {
    local grafana_route
    grafana_route=$(oc get route -n "$NS" -l app=grafana \
        -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  완료! 모니터링 실습 환경이 준비되었습니다.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    if [ "${GRAFANA_INSTALLED:-false}" = "true" ]; then
        if [ -n "$grafana_route" ]; then
            echo -e "  Grafana URL : ${CYAN}https://${grafana_route}${NC}"
            echo -e "  계정        : admin / ${GRAFANA_ADMIN_PASS:-grafana123}"
        else
            echo -e "  Grafana Route: ${CYAN}oc get route -n ${NS}${NC}"
        fi
        echo ""
    fi

    if [ "${COO_INSTALLED:-false}" = "true" ]; then
        echo -e "  COO MonitoringStack:"
        echo -e "    ${CYAN}oc get monitoringstack -n ${NS}${NC}"
        echo -e "  ServiceMonitor (COO):"
        echo -e "    ${CYAN}oc get servicemonitor.monitoring.rhobs -n ${NS}${NC}"
        echo -e "  PrometheusRule:"
        echo -e "    ${CYAN}oc get prometheusrule -n ${NS}${NC}"
        echo ""
        echo -e "  COO Prometheus 직접 접근 (port-forward):"
        echo -e "    ${CYAN}oc port-forward svc/prometheus-operated 9090:9090 -n ${NS}${NC}"
        echo -e "    브라우저: ${CYAN}http://localhost:9090${NC}"
        echo ""
    fi

    if [ "${VIRT_INSTALLED:-false}" = "true" ] && [ "${COO_INSTALLED:-false}" = "true" ]; then
        echo -e "  VM 상태:"
        echo -e "    ${CYAN}oc get vmi ${VM_NAME} -n ${NS}${NC}"
        echo -e "  OpenShift Console → Observe → Metrics:"
        echo -e "    ${CYAN}node_memory_MemAvailable_bytes{job=\"poc-monitoring-vm\"}${NC}"
        echo ""
    fi

    echo -e "  Pod 상태 확인:"
    echo -e "    ${CYAN}oc get pods -n ${NS}${NC}"
    echo ""
    echo -e "  자세한 내용: 10-monitoring.md 참조"
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
    step_vm
    step_coo
    print_summary
}

main
