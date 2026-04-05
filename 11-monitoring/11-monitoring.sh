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

    # env.conf에 없으면 클러스터 CSV에서 자동 감지
    if [ "${GRAFANA_INSTALLED:-false}" != "true" ]; then
        if oc get csv --all-namespaces --no-headers 2>/dev/null \
            | grep -qi "grafana-operator"; then
            GRAFANA_INSTALLED=true
            print_ok "Grafana 커뮤니티 Operator 자동 감지 (CSV)"
        fi
    fi

    if [ "${COO_INSTALLED:-false}" != "true" ]; then
        if oc get csv --all-namespaces --no-headers 2>/dev/null \
            | grep -qi "cluster-observability-operator"; then
            COO_INSTALLED=true
            print_ok "Cluster Observability Operator 자동 감지 (CSV)"
        fi
    fi

    if [ "${VIRT_INSTALLED:-false}" != "true" ]; then
        if oc get csv --all-namespaces --no-headers 2>/dev/null \
            | grep -qi "kubevirt-hyperconverged"; then
            VIRT_INSTALLED=true
            print_ok "OpenShift Virtualization 자동 감지 (CSV)"
        fi
    fi

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
        local ns_phase
        ns_phase=$(oc get namespace "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

        if [ "$ns_phase" = "Terminating" ]; then
            print_warn "네임스페이스 $NS 가 Terminating 상태 — 삭제 완료 대기 중..."
            local retries=36
            local i=0
            while [ "$i" -lt "$retries" ]; do
                if ! oc get namespace "$NS" &>/dev/null; then
                    print_ok "네임스페이스 삭제 완료"
                    break
                fi
                printf "  [%d/%d] Terminating 대기 중...\r" "$((i+1))" "$retries"
                sleep 5
                i=$((i+1))
            done
            echo ""

            if oc get namespace "$NS" &>/dev/null; then
                print_error "네임스페이스 $NS 가 여전히 Terminating 상태입니다."
                print_info "수동 확인: oc get namespace $NS -o yaml"
                print_info "Finalizer 강제 제거: oc patch namespace $NS -p '{\"metadata\":{\"finalizers\":[]}}' --type=merge"
                exit 1
            fi

            oc new-project "$NS" > /dev/null
            print_ok "네임스페이스 $NS 재생성 완료"
        else
            print_ok "네임스페이스 $NS 이미 존재 (Active) — 스킵"
        fi
    else
        oc new-project "$NS" > /dev/null
        print_ok "네임스페이스 $NS 생성 완료"
    fi
}

step_grafana() {
    if [ "${GRAFANA_INSTALLED:-false}" != "true" ]; then
        return
    fi
    print_step "2/6  Grafana 인스턴스 배포"

    local grafana_pass="${GRAFANA_ADMIN_PASS:-grafana123}"

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
      admin_password: ${grafana_pass}
EOF
        oc apply -f /tmp/poc-grafana.yaml
        print_ok "Grafana poc-grafana 배포 완료 (admin 비밀번호: ${grafana_pass})"
    fi

    # Grafana Pod Ready 대기
    print_info "Grafana Pod 준비 대기 중..."
    local retries=24
    local i=0
    while [ "$i" -lt "$retries" ]; do
        local ready
        ready=$(oc get pods -n "$NS" -l "app=poc-grafana" \
            --no-headers 2>/dev/null | awk '{print $2}' | head -1)
        if [ "${ready}" = "1/1" ]; then
            print_ok "Grafana Pod Ready"
            break
        fi
        printf "  [%d/%d] 대기 중... (%s)\r" "$((i+1))" "$retries" "${ready:--}"
        sleep 5
        i=$((i+1))
    done
    echo ""

    # OpenShift Route 생성 (ingress 대신 Route 직접 생성)
    if oc get route poc-grafana-route -n "$NS" &>/dev/null; then
        print_ok "Route poc-grafana-route 이미 존재 — 스킵"
    else
        cat > /tmp/poc-grafana-route.yaml <<EOF
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: poc-grafana-route
  namespace: ${NS}
  labels:
    app: grafana
spec:
  to:
    kind: Service
    name: poc-grafana-service
  port:
    targetPort: grafana
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF
        oc apply -f /tmp/poc-grafana-route.yaml
        print_ok "Route poc-grafana-route 생성 완료"
    fi

    local grafana_url
    grafana_url=$(oc get route poc-grafana-route -n "$NS" \
        -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    [ -n "$grafana_url" ] && print_ok "Grafana URL: https://${grafana_url}"
    print_info "  로그인: admin / ${grafana_pass}"

    # Grafana SA 생성 대기 (Grafana Operator가 SA를 비동기로 생성)
    print_info "ServiceAccount poc-grafana-sa 생성 대기 중..."
    local sa_retries=24
    local si=0
    while [ "$si" -lt "$sa_retries" ]; do
        if oc get serviceaccount poc-grafana-sa -n "$NS" &>/dev/null; then
            print_ok "ServiceAccount poc-grafana-sa 확인"
            break
        fi
        printf "  [%d/%d] SA 대기 중...\r" "$((si+1))" "$sa_retries"
        sleep 5
        si=$((si+1))
    done
    echo ""

    # Grafana SA에 cluster-monitoring-view 권한 부여 (oc apply — 멱등)
    print_info "Prometheus 접근 권한 설정 중..."
    cat > /tmp/grafana-monitoring-crb.yaml <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: grafana-cluster-monitoring-view
subjects:
- kind: ServiceAccount
  name: poc-grafana-sa
  namespace: ${NS}
roleRef:
  kind: ClusterRole
  name: cluster-monitoring-view
  apiGroup: rbac.authorization.k8s.io
EOF
    oc apply --server-side -f /tmp/grafana-monitoring-crb.yaml
    print_ok "cluster-monitoring-view ClusterRoleBinding 적용 완료"
}

step_datasource() {
    if [ "${GRAFANA_INSTALLED:-false}" != "true" ]; then
        return
    fi
    print_step "3/6  Prometheus DataSource 연동"

    # ServiceAccount 존재 확인 (step_grafana에서 대기했지만 한 번 더 보장)
    if ! oc get serviceaccount poc-grafana-sa -n "$NS" &>/dev/null; then
        print_warn "ServiceAccount poc-grafana-sa 없음 — DataSource 스텝 건너뜁니다."
        print_info "수동 확인: oc get sa -n ${NS}"
        return
    fi

    # ServiceAccount 토큰 생성 (재시도 3회)
    TOKEN=""
    local t=0
    while [ "$t" -lt 3 ] && [ -z "$TOKEN" ]; do
        TOKEN=$(oc create token poc-grafana-sa -n "$NS" --duration=8760h 2>/dev/null || true)
        [ -z "$TOKEN" ] && sleep 5
        t=$((t+1))
    done
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

step_dashboard() {
    if [ "${GRAFANA_INSTALLED:-false}" != "true" ]; then
        return
    fi
    print_step "4/6  VM 전체 현황 대시보드 배포"

    # 이미 존재해도 최신 JSON으로 업데이트 (oc apply)
    if oc get grafanadashboard poc-vm-overview -n "$NS" &>/dev/null; then
        print_info "GrafanaDashboard poc-vm-overview 이미 존재 — 최신 버전으로 갱신"
    fi

    # Dashboard JSON ($-확장 방지: single-quoted heredoc 사용)
    cat > /tmp/poc-vm-dashboard.json << 'DASHBOARD_EOF'
{
  "annotations": {
    "list": [
      {
        "builtIn": 1,
        "datasource": {"type": "grafana", "uid": "-- Grafana --"},
        "enable": true,
        "hide": true,
        "iconColor": "rgba(0, 211, 255, 1)",
        "name": "Annotations & Alerts",
        "type": "dashboard"
      }
    ]
  },
  "description": "OpenShift Virtualization 전체 VM 운영 현황 모니터링",
  "editable": true,
  "fiscalYearStartMonth": 0,
  "graphTooltip": 1,
  "id": null,
  "links": [],
  "refresh": "30s",
  "schemaVersion": 39,
  "tags": ["kubevirt", "vm", "poc", "openshift-virtualization"],
  "templating": {
    "list": [
      {
        "current": {"selected": false, "text": "Prometheus", "value": "Prometheus"},
        "hide": 0,
        "includeAll": false,
        "label": "데이터소스",
        "multi": false,
        "name": "datasource",
        "options": [],
        "query": "prometheus",
        "refresh": 1,
        "type": "datasource"
      },
      {
        "allValue": ".*",
        "current": {"selected": true, "text": "All", "value": "$__all"},
        "datasource": {"type": "prometheus", "uid": "${datasource}"},
        "definition": "label_values(kubevirt_vmi_info, namespace)",
        "hide": 0,
        "includeAll": true,
        "label": "네임스페이스",
        "multi": true,
        "name": "namespace",
        "options": [],
        "query": {"query": "label_values(kubevirt_vmi_info, namespace)", "refId": "Q"},
        "refresh": 2,
        "regex": "",
        "sort": 1,
        "type": "query"
      },
      {
        "allValue": ".*",
        "current": {"selected": true, "text": "All", "value": "$__all"},
        "datasource": {"type": "prometheus", "uid": "${datasource}"},
        "definition": "label_values(kubevirt_vmi_info, name)",
        "hide": 0,
        "includeAll": true,
        "label": "VM 이름",
        "multi": true,
        "name": "vm",
        "options": [],
        "query": {"query": "label_values(kubevirt_vmi_info, name)", "refId": "Q"},
        "refresh": 2,
        "regex": "",
        "sort": 1,
        "type": "query"
      }
    ]
  },
  "time": {"from": "now-1h", "to": "now"},
  "timepicker": {},
  "timezone": "browser",
  "title": "KubeVirt VM 전체 현황",
  "uid": "poc-vm-overview",
  "version": 1,
  "panels": [
    {
      "collapsed": false,
      "gridPos": {"h": 1, "w": 24, "x": 0, "y": 0},
      "id": 100,
      "title": "VM 상태 요약",
      "type": "row"
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {
        "defaults": {
          "color": {"fixedColor": "green", "mode": "fixed"},
          "mappings": [],
          "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}]},
          "unit": "short"
        },
        "overrides": []
      },
      "gridPos": {"h": 4, "w": 6, "x": 0, "y": 1},
      "id": 1,
      "options": {
        "colorMode": "background",
        "graphMode": "area",
        "justifyMode": "center",
        "orientation": "auto",
        "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false},
        "textMode": "auto"
      },
      "title": "실행 중 (Running) — 클러스터 전체",
      "type": "stat",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "sum(kubevirt_vmi_phase_count{phase=~\"Running|running\"}) or vector(0)",
          "legendFormat": "Running",
          "refId": "A"
        }
      ]
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {
        "defaults": {
          "color": {"fixedColor": "yellow", "mode": "fixed"},
          "mappings": [],
          "thresholds": {"mode": "absolute", "steps": [{"color": "yellow", "value": null}]},
          "unit": "short"
        },
        "overrides": []
      },
      "gridPos": {"h": 4, "w": 6, "x": 6, "y": 1},
      "id": 2,
      "options": {
        "colorMode": "background",
        "graphMode": "area",
        "justifyMode": "center",
        "orientation": "auto",
        "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false},
        "textMode": "auto"
      },
      "title": "일시정지 (Paused) — 클러스터 전체",
      "type": "stat",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "sum(kubevirt_vmi_phase_count{phase=~\"Paused|paused\"}) or vector(0)",
          "legendFormat": "Paused",
          "refId": "A"
        }
      ]
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {
        "defaults": {
          "color": {"fixedColor": "red", "mode": "fixed"},
          "mappings": [],
          "thresholds": {"mode": "absolute", "steps": [{"color": "red", "value": null}]},
          "unit": "short"
        },
        "overrides": []
      },
      "gridPos": {"h": 4, "w": 6, "x": 12, "y": 1},
      "id": 3,
      "options": {
        "colorMode": "background",
        "graphMode": "area",
        "justifyMode": "center",
        "orientation": "auto",
        "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false},
        "textMode": "auto"
      },
      "title": "비정상 VMI (Pending / Failed) — 클러스터 전체",
      "type": "stat",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "sum(kubevirt_vmi_phase_count{phase!~\"Running|running|Paused|paused\"}) or vector(0)",
          "legendFormat": "비정상 (Pending/Failed 등)",
          "refId": "A"
        }
      ]
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {
        "defaults": {
          "color": {"fixedColor": "blue", "mode": "fixed"},
          "mappings": [],
          "thresholds": {"mode": "absolute", "steps": [{"color": "blue", "value": null}]},
          "unit": "short"
        },
        "overrides": []
      },
      "gridPos": {"h": 4, "w": 6, "x": 18, "y": 1},
      "id": 4,
      "options": {
        "colorMode": "background",
        "graphMode": "area",
        "justifyMode": "center",
        "orientation": "auto",
        "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false},
        "textMode": "auto"
      },
      "title": "전체 활성 VMI — 클러스터 전체",
      "type": "stat",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "count(kubevirt_vmi_info) or vector(0)",
          "legendFormat": "Total",
          "refId": "A"
        }
      ]
    },
    {
      "collapsed": false,
      "gridPos": {"h": 1, "w": 24, "x": 0, "y": 5},
      "id": 101,
      "title": "VM 인벤토리",
      "type": "row"
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "thresholds"},
          "custom": {
            "align": "auto",
            "cellOptions": {"type": "auto"},
            "filterable": true,
            "inspect": false
          },
          "mappings": [],
          "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}]}
        },
        "overrides": [
          {
            "matcher": {"id": "byName", "options": "ready"},
            "properties": [
              {
                "id": "mappings",
                "value": [
                  {"options": {"true":  {"color": "green", "index": 0, "text": "Ready"}},  "type": "value"},
                  {"options": {"false": {"color": "red",   "index": 1, "text": "Not Ready"}}, "type": "value"}
                ]
              },
              {"id": "custom.cellOptions", "value": {"type": "color-text"}}
            ]
          },
          {"matcher": {"id": "byName", "options": "Value"}, "properties": [{"id": "custom.hidden", "value": true}]},
          {"matcher": {"id": "byName", "options": "Time"},  "properties": [{"id": "custom.hidden", "value": true}]}
        ]
      },
      "gridPos": {"h": 8, "w": 24, "x": 0, "y": 6},
      "id": 5,
      "options": {
        "cellHeight": "sm",
        "footer": {"countRows": false, "fields": "", "reducer": ["sum"], "show": false},
        "showHeader": true,
        "sortBy": [{"desc": false, "displayName": "namespace"}]
      },
      "title": "VM 목록",
      "transformations": [
        {"id": "merge", "options": {}},
        {"id": "labelsToFields", "options": {"mode": "columns"}},
        {
          "id": "organize",
          "options": {
            "excludeByName": {"__name__": true, "job": true, "instance": true},
            "indexByName": {},
            "renameByName": {
              "namespace": "네임스페이스",
              "name":      "VM 이름",
              "node":      "노드",
              "ready":     "Ready 상태",
              "os":        "OS",
              "workload":  "워크로드"
            }
          }
        }
      ],
      "type": "table",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "kubevirt_vmi_info",
          "instant": true,
          "legendFormat": "{{name}}",
          "refId": "A"
        }
      ]
    },
    {
      "collapsed": false,
      "gridPos": {"h": 1, "w": 24, "x": 0, "y": 14},
      "id": 102,
      "title": "CPU",
      "type": "row"
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "palette-classic"},
          "custom": {
            "axisBorderShow": false, "axisCenteredZero": false, "axisColorMode": "text",
            "axisLabel": "", "axisPlacement": "auto", "barAlignment": 0,
            "drawStyle": "line", "fillOpacity": 10, "gradientMode": "none",
            "hideFrom": {"legend": false, "tooltip": false, "viz": false},
            "lineInterpolation": "linear", "lineWidth": 1, "pointSize": 5,
            "scaleDistribution": {"type": "linear"}, "showPoints": "never",
            "spanNulls": false, "stacking": {"group": "A", "mode": "none"},
            "thresholdsStyle": {"mode": "off"}
          },
          "mappings": [],
          "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}]},
          "unit": "short"
        },
        "overrides": []
      },
      "gridPos": {"h": 8, "w": 24, "x": 0, "y": 15},
      "id": 6,
      "options": {
        "legend": {"calcs": ["mean", "max", "last"], "displayMode": "table", "placement": "bottom", "showLegend": true},
        "tooltip": {"mode": "multi", "sort": "desc"}
      },
      "title": "CPU 사용률 (vCPU seconds/s)",
      "type": "timeseries",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "rate(kubevirt_vmi_cpu_usage_seconds_total{namespace=~\"$namespace\", name=~\"$vm\"}[5m])",
          "legendFormat": "{{namespace}}/{{name}}",
          "refId": "A"
        }
      ]
    },
    {
      "collapsed": false,
      "gridPos": {"h": 1, "w": 24, "x": 0, "y": 23},
      "id": 103,
      "title": "메모리",
      "type": "row"
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "palette-classic"},
          "custom": {
            "axisBorderShow": false, "axisCenteredZero": false, "axisColorMode": "text",
            "axisLabel": "", "axisPlacement": "auto", "barAlignment": 0,
            "drawStyle": "line", "fillOpacity": 10, "gradientMode": "none",
            "hideFrom": {"legend": false, "tooltip": false, "viz": false},
            "lineInterpolation": "linear", "lineWidth": 1, "pointSize": 5,
            "scaleDistribution": {"type": "linear"}, "showPoints": "never",
            "spanNulls": false, "stacking": {"group": "A", "mode": "none"},
            "thresholdsStyle": {"mode": "off"}
          },
          "mappings": [],
          "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}]},
          "unit": "bytes"
        },
        "overrides": []
      },
      "gridPos": {"h": 8, "w": 12, "x": 0, "y": 24},
      "id": 7,
      "options": {
        "legend": {"calcs": ["mean", "max", "last"], "displayMode": "table", "placement": "bottom", "showLegend": true},
        "tooltip": {"mode": "multi", "sort": "desc"}
      },
      "title": "메모리 사용량 (Resident)",
      "type": "timeseries",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "kubevirt_vmi_memory_resident_bytes{namespace=~\"$namespace\", name=~\"$vm\"}",
          "legendFormat": "{{namespace}}/{{name}}",
          "refId": "A"
        }
      ]
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "palette-classic"},
          "custom": {
            "axisBorderShow": false, "axisCenteredZero": false, "axisColorMode": "text",
            "axisLabel": "", "axisPlacement": "auto", "barAlignment": 0,
            "drawStyle": "line", "fillOpacity": 10, "gradientMode": "none",
            "hideFrom": {"legend": false, "tooltip": false, "viz": false},
            "lineInterpolation": "linear", "lineWidth": 1, "pointSize": 5,
            "scaleDistribution": {"type": "linear"}, "showPoints": "never",
            "spanNulls": false, "stacking": {"group": "A", "mode": "none"},
            "thresholdsStyle": {"mode": "off"}
          },
          "mappings": [],
          "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "red", "value": 0.9}]},
          "unit": "percentunit",
          "min": 0,
          "max": 1
        },
        "overrides": []
      },
      "gridPos": {"h": 8, "w": 12, "x": 12, "y": 24},
      "id": 8,
      "options": {
        "legend": {"calcs": ["mean", "max", "last"], "displayMode": "table", "placement": "bottom", "showLegend": true},
        "tooltip": {"mode": "multi", "sort": "desc"}
      },
      "title": "메모리 사용률 (%)",
      "type": "timeseries",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "kubevirt_vmi_memory_resident_bytes{namespace=~\"$namespace\", name=~\"$vm\"} / (kubevirt_vmi_memory_resident_bytes{namespace=~\"$namespace\", name=~\"$vm\"} + kubevirt_vmi_memory_available_bytes{namespace=~\"$namespace\", name=~\"$vm\"})",
          "legendFormat": "{{namespace}}/{{name}}",
          "refId": "A"
        }
      ]
    },
    {
      "collapsed": false,
      "gridPos": {"h": 1, "w": 24, "x": 0, "y": 32},
      "id": 104,
      "title": "네트워크 I/O",
      "type": "row"
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "palette-classic"},
          "custom": {
            "axisBorderShow": false, "axisCenteredZero": false, "axisColorMode": "text",
            "axisLabel": "", "axisPlacement": "auto", "barAlignment": 0,
            "drawStyle": "line", "fillOpacity": 10, "gradientMode": "none",
            "hideFrom": {"legend": false, "tooltip": false, "viz": false},
            "lineInterpolation": "linear", "lineWidth": 1, "pointSize": 5,
            "scaleDistribution": {"type": "linear"}, "showPoints": "never",
            "spanNulls": false, "stacking": {"group": "A", "mode": "none"},
            "thresholdsStyle": {"mode": "off"}
          },
          "mappings": [],
          "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}]},
          "unit": "Bps"
        },
        "overrides": []
      },
      "gridPos": {"h": 8, "w": 12, "x": 0, "y": 33},
      "id": 9,
      "options": {
        "legend": {"calcs": ["mean", "max", "last"], "displayMode": "table", "placement": "bottom", "showLegend": true},
        "tooltip": {"mode": "multi", "sort": "desc"}
      },
      "title": "네트워크 수신 (RX)",
      "type": "timeseries",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "rate(kubevirt_vmi_network_receive_bytes_total{namespace=~\"$namespace\", name=~\"$vm\"}[5m])",
          "legendFormat": "{{namespace}}/{{name}} [{{interface}}]",
          "refId": "A"
        }
      ]
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "palette-classic"},
          "custom": {
            "axisBorderShow": false, "axisCenteredZero": false, "axisColorMode": "text",
            "axisLabel": "", "axisPlacement": "auto", "barAlignment": 0,
            "drawStyle": "line", "fillOpacity": 10, "gradientMode": "none",
            "hideFrom": {"legend": false, "tooltip": false, "viz": false},
            "lineInterpolation": "linear", "lineWidth": 1, "pointSize": 5,
            "scaleDistribution": {"type": "linear"}, "showPoints": "never",
            "spanNulls": false, "stacking": {"group": "A", "mode": "none"},
            "thresholdsStyle": {"mode": "off"}
          },
          "mappings": [],
          "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}]},
          "unit": "Bps"
        },
        "overrides": []
      },
      "gridPos": {"h": 8, "w": 12, "x": 12, "y": 33},
      "id": 10,
      "options": {
        "legend": {"calcs": ["mean", "max", "last"], "displayMode": "table", "placement": "bottom", "showLegend": true},
        "tooltip": {"mode": "multi", "sort": "desc"}
      },
      "title": "네트워크 송신 (TX)",
      "type": "timeseries",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "rate(kubevirt_vmi_network_transmit_bytes_total{namespace=~\"$namespace\", name=~\"$vm\"}[5m])",
          "legendFormat": "{{namespace}}/{{name}} [{{interface}}]",
          "refId": "A"
        }
      ]
    },
    {
      "collapsed": false,
      "gridPos": {"h": 1, "w": 24, "x": 0, "y": 41},
      "id": 105,
      "title": "스토리지 I/O",
      "type": "row"
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "palette-classic"},
          "custom": {
            "axisBorderShow": false, "axisCenteredZero": false, "axisColorMode": "text",
            "axisLabel": "", "axisPlacement": "auto", "barAlignment": 0,
            "drawStyle": "line", "fillOpacity": 10, "gradientMode": "none",
            "hideFrom": {"legend": false, "tooltip": false, "viz": false},
            "lineInterpolation": "linear", "lineWidth": 1, "pointSize": 5,
            "scaleDistribution": {"type": "linear"}, "showPoints": "never",
            "spanNulls": false, "stacking": {"group": "A", "mode": "none"},
            "thresholdsStyle": {"mode": "off"}
          },
          "mappings": [],
          "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}]},
          "unit": "Bps"
        },
        "overrides": []
      },
      "gridPos": {"h": 8, "w": 12, "x": 0, "y": 42},
      "id": 11,
      "options": {
        "legend": {"calcs": ["mean", "max", "last"], "displayMode": "table", "placement": "bottom", "showLegend": true},
        "tooltip": {"mode": "multi", "sort": "desc"}
      },
      "title": "스토리지 읽기 (Read)",
      "type": "timeseries",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "rate(kubevirt_vmi_storage_read_traffic_bytes_total{namespace=~\"$namespace\", name=~\"$vm\"}[5m])",
          "legendFormat": "{{namespace}}/{{name}} [{{drive}}]",
          "refId": "A"
        }
      ]
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "palette-classic"},
          "custom": {
            "axisBorderShow": false, "axisCenteredZero": false, "axisColorMode": "text",
            "axisLabel": "", "axisPlacement": "auto", "barAlignment": 0,
            "drawStyle": "line", "fillOpacity": 10, "gradientMode": "none",
            "hideFrom": {"legend": false, "tooltip": false, "viz": false},
            "lineInterpolation": "linear", "lineWidth": 1, "pointSize": 5,
            "scaleDistribution": {"type": "linear"}, "showPoints": "never",
            "spanNulls": false, "stacking": {"group": "A", "mode": "none"},
            "thresholdsStyle": {"mode": "off"}
          },
          "mappings": [],
          "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}]},
          "unit": "Bps"
        },
        "overrides": []
      },
      "gridPos": {"h": 8, "w": 12, "x": 12, "y": 42},
      "id": 12,
      "options": {
        "legend": {"calcs": ["mean", "max", "last"], "displayMode": "table", "placement": "bottom", "showLegend": true},
        "tooltip": {"mode": "multi", "sort": "desc"}
      },
      "title": "스토리지 쓰기 (Write)",
      "type": "timeseries",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "rate(kubevirt_vmi_storage_write_traffic_bytes_total{namespace=~\"$namespace\", name=~\"$vm\"}[5m])",
          "legendFormat": "{{namespace}}/{{name}} [{{drive}}]",
          "refId": "A"
        }
      ]
    }
  ]
}
DASHBOARD_EOF

    # YAML 래퍼 생성 (bash 변수 ${NS} 사용)
    {
        printf 'apiVersion: grafana.integreatly.org/v1beta1\n'
        printf 'kind: GrafanaDashboard\n'
        printf 'metadata:\n'
        printf '  name: poc-vm-overview\n'
        printf '  namespace: %s\n' "${NS}"
        printf '  labels:\n'
        printf '    app: poc-grafana\n'
        printf 'spec:\n'
        printf '  instanceSelector:\n'
        printf '    matchLabels:\n'
        printf '      dashboards: poc-grafana\n'
        printf '  json: |\n'
        sed 's/^/    /' /tmp/poc-vm-dashboard.json
    } > /tmp/poc-vm-dashboard.yaml

    oc apply -f /tmp/poc-vm-dashboard.yaml
    print_ok "GrafanaDashboard poc-vm-overview 배포 완료"
    print_info "  대시보드: Grafana → Dashboards → KubeVirt VM 전체 현황"
}

step_vm() {
    if [ "${COO_INSTALLED:-false}" != "true" ] || [ "${VIRT_INSTALLED:-false}" != "true" ]; then
        return
    fi
    print_step "5/6  poc 템플릿 VM 생성 (${VM_NAME})"

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
    print_step "6/7  Cluster Observability Operator (COO) 구성"

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
          expr: kubevirt_vmi_phase_count{phase!~"Running|running|Paused|paused"} > 0
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

    # 전체 네임스페이스의 VMI node_exporter 스크랩 설정
    print_info "클러스터 전체 VMI node_exporter Service/ServiceMonitor 설정 중..."
    local vmi_ns_list
    vmi_ns_list=$(oc get vmi --all-namespaces --no-headers 2>/dev/null \
        | awk '{print $1}' | sort -u || true)

    if [ -z "$vmi_ns_list" ]; then
        print_warn "실행 중인 VMI 없음 — 네임스페이스별 node_exporter 설정 건너뜁니다."
    else
        while IFS= read -r vmi_ns; do
            [ -z "$vmi_ns" ] && continue

            # virt-launcher 파드에 monitor=metrics 레이블 부여
            oc label pods -n "$vmi_ns" -l "kubevirt.io=virt-launcher" \
                monitor=metrics --overwrite 2>/dev/null || true

            # Headless Service — 각 파드에서 node_exporter(9100) 직접 수집
            cat > /tmp/vm-ne-svc.yaml <<EOF
apiVersion: v1
kind: Service
metadata:
  name: vm-node-exporter
  namespace: ${vmi_ns}
  labels:
    app: vm-node-exporter
    monitoring.rhobs/stack: poc-monitoring-stack
spec:
  clusterIP: None
  ports:
    - name: metrics
      port: 9100
      targetPort: 9100
  selector:
    monitor: metrics
EOF
            oc apply -f /tmp/vm-ne-svc.yaml

            # ServiceMonitor (monitoring.rhobs/v1 — COO 전용)
            cat > /tmp/vm-ne-sm.yaml <<EOF
apiVersion: monitoring.rhobs/v1
kind: ServiceMonitor
metadata:
  name: vm-node-exporter
  namespace: ${vmi_ns}
  labels:
    monitoring.rhobs/stack: poc-monitoring-stack
spec:
  selector:
    matchLabels:
      app: vm-node-exporter
  endpoints:
    - port: metrics
      interval: 30s
      path: /metrics
      relabelings:
        - targetLabel: job
          replacement: vm-node-exporter
        - sourceLabels: [__meta_kubernetes_pod_label_vm_kubevirt_io_name]
          targetLabel: vmname
        - targetLabel: vm_namespace
          replacement: ${vmi_ns}
EOF
            oc apply -f /tmp/vm-ne-sm.yaml

            print_ok "  [${vmi_ns}] Service + ServiceMonitor 완료"
        done <<< "$vmi_ns_list"
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

step_coo_dashboard() {
    if [ "${GRAFANA_INSTALLED:-false}" != "true" ] || [ "${COO_INSTALLED:-false}" != "true" ]; then
        return
    fi
    print_step "7/7  VM OS 메트릭 대시보드 배포 (COO-Prometheus / node_exporter)"

    cat > /tmp/poc-vm-node-exporter-dashboard.json << 'NEDASHEOF'
{
  "annotations": {"list": [{"builtIn": 1, "datasource": {"type": "grafana", "uid": "-- Grafana --"}, "enable": true, "hide": true, "iconColor": "rgba(0,211,255,1)", "name": "Annotations & Alerts", "type": "dashboard"}]},
  "description": "VM 내부 OS 메트릭 (node_exporter) — COO-Prometheus 기반",
  "editable": true,
  "fiscalYearStartMonth": 0,
  "graphTooltip": 1,
  "id": null,
  "links": [],
  "refresh": "30s",
  "schemaVersion": 39,
  "tags": ["node-exporter", "vm", "poc", "coo"],
  "templating": {
    "list": [
      {
        "current": {"selected": false, "text": "COO-Prometheus", "value": "COO-Prometheus"},
        "hide": 0,
        "includeAll": false,
        "label": "데이터소스",
        "multi": false,
        "name": "datasource",
        "options": [],
        "query": "prometheus",
        "refresh": 1,
        "type": "datasource"
      },
      {
        "allValue": ".*",
        "current": {"selected": true, "text": "All", "value": "$__all"},
        "datasource": {"type": "prometheus", "uid": "${datasource}"},
        "definition": "label_values(node_cpu_seconds_total{job=\"vm-node-exporter\"}, vm_namespace)",
        "hide": 0,
        "includeAll": true,
        "label": "네임스페이스",
        "multi": true,
        "name": "vm_namespace",
        "options": [],
        "query": {"query": "label_values(node_cpu_seconds_total{job=\"vm-node-exporter\"}, vm_namespace)", "refId": "Q"},
        "refresh": 2,
        "regex": "",
        "sort": 1,
        "type": "query"
      },
      {
        "allValue": ".*",
        "current": {"selected": true, "text": "All", "value": "$__all"},
        "datasource": {"type": "prometheus", "uid": "${datasource}"},
        "definition": "label_values(node_cpu_seconds_total{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\"}, vmname)",
        "hide": 0,
        "includeAll": true,
        "label": "VM 이름",
        "multi": true,
        "name": "vmname",
        "options": [],
        "query": {"query": "label_values(node_cpu_seconds_total{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\"}, vmname)", "refId": "Q"},
        "refresh": 2,
        "regex": "",
        "sort": 1,
        "type": "query"
      }
    ]
  },
  "time": {"from": "now-1h", "to": "now"},
  "timepicker": {},
  "timezone": "browser",
  "title": "VM OS 메트릭 (node_exporter / COO)",
  "uid": "poc-vm-node-exporter",
  "version": 1,
  "panels": [
    {
      "collapsed": false,
      "gridPos": {"h": 1, "w": 24, "x": 0, "y": 0},
      "id": 100,
      "title": "VM 현황 요약",
      "type": "row"
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "thresholds"},
          "mappings": [],
          "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "yellow", "value": 70}, {"color": "red", "value": 90}]},
          "unit": "percent", "min": 0, "max": 100
        },
        "overrides": []
      },
      "gridPos": {"h": 4, "w": 12, "x": 0, "y": 1},
      "id": 1,
      "options": {"colorMode": "background", "graphMode": "area", "justifyMode": "center", "orientation": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}, "textMode": "auto"},
      "title": "VM CPU 평균 사용률",
      "type": "stat",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "100 - avg(rate(node_cpu_seconds_total{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\", vmname=~\"$vmname\", mode=\"idle\"}[5m])) * 100",
          "legendFormat": "CPU %",
          "refId": "A"
        }
      ]
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "thresholds"},
          "mappings": [],
          "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "yellow", "value": 70}, {"color": "red", "value": 90}]},
          "unit": "percent", "min": 0, "max": 100
        },
        "overrides": []
      },
      "gridPos": {"h": 4, "w": 12, "x": 12, "y": 1},
      "id": 2,
      "options": {"colorMode": "background", "graphMode": "area", "justifyMode": "center", "orientation": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}, "textMode": "auto"},
      "title": "VM 메모리 평균 사용률",
      "type": "stat",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "100 * (1 - avg(node_memory_MemAvailable_bytes{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\", vmname=~\"$vmname\"} / node_memory_MemTotal_bytes{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\", vmname=~\"$vmname\"}))",
          "legendFormat": "메모리 %",
          "refId": "A"
        }
      ]
    },
    {
      "collapsed": false,
      "gridPos": {"h": 1, "w": 24, "x": 0, "y": 5},
      "id": 101,
      "title": "CPU",
      "type": "row"
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "palette-classic"},
          "custom": {"axisBorderShow": false, "axisColorMode": "text", "axisLabel": "", "axisPlacement": "auto", "barAlignment": 0, "drawStyle": "line", "fillOpacity": 10, "gradientMode": "none", "hideFrom": {"legend": false, "tooltip": false, "viz": false}, "lineInterpolation": "linear", "lineWidth": 1, "pointSize": 5, "scaleDistribution": {"type": "linear"}, "showPoints": "never", "spanNulls": false, "stacking": {"group": "A", "mode": "none"}, "thresholdsStyle": {"mode": "off"}},
          "mappings": [],
          "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}]},
          "unit": "percent", "min": 0, "max": 100
        },
        "overrides": []
      },
      "gridPos": {"h": 8, "w": 24, "x": 0, "y": 6},
      "id": 3,
      "options": {"legend": {"calcs": ["mean", "max", "last"], "displayMode": "table", "placement": "bottom", "showLegend": true}, "tooltip": {"mode": "multi", "sort": "desc"}},
      "title": "CPU 사용률 (%) — VM별",
      "type": "timeseries",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "100 - rate(node_cpu_seconds_total{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\", vmname=~\"$vmname\", mode=\"idle\"}[5m]) * 100",
          "legendFormat": "{{vm_namespace}}/{{vmname}} cpu{{cpu}}",
          "refId": "A"
        }
      ]
    },
    {
      "collapsed": false,
      "gridPos": {"h": 1, "w": 24, "x": 0, "y": 14},
      "id": 102,
      "title": "메모리",
      "type": "row"
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "palette-classic"},
          "custom": {"axisBorderShow": false, "axisColorMode": "text", "axisLabel": "", "axisPlacement": "auto", "barAlignment": 0, "drawStyle": "line", "fillOpacity": 10, "gradientMode": "none", "hideFrom": {"legend": false, "tooltip": false, "viz": false}, "lineInterpolation": "linear", "lineWidth": 1, "pointSize": 5, "scaleDistribution": {"type": "linear"}, "showPoints": "never", "spanNulls": false, "stacking": {"group": "A", "mode": "none"}, "thresholdsStyle": {"mode": "off"}},
          "mappings": [],
          "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}]},
          "unit": "bytes"
        },
        "overrides": []
      },
      "gridPos": {"h": 8, "w": 12, "x": 0, "y": 15},
      "id": 4,
      "options": {"legend": {"calcs": ["mean", "max", "last"], "displayMode": "table", "placement": "bottom", "showLegend": true}, "tooltip": {"mode": "multi", "sort": "desc"}},
      "title": "메모리 사용량 (Used)",
      "type": "timeseries",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "node_memory_MemTotal_bytes{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\", vmname=~\"$vmname\"} - node_memory_MemAvailable_bytes{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\", vmname=~\"$vmname\"}",
          "legendFormat": "{{vm_namespace}}/{{vmname}} used",
          "refId": "A"
        },
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "node_memory_MemTotal_bytes{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\", vmname=~\"$vmname\"}",
          "legendFormat": "{{vm_namespace}}/{{vmname}} total",
          "refId": "B"
        }
      ]
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "palette-classic"},
          "custom": {"axisBorderShow": false, "axisColorMode": "text", "axisLabel": "", "axisPlacement": "auto", "barAlignment": 0, "drawStyle": "line", "fillOpacity": 10, "gradientMode": "none", "hideFrom": {"legend": false, "tooltip": false, "viz": false}, "lineInterpolation": "linear", "lineWidth": 1, "pointSize": 5, "scaleDistribution": {"type": "linear"}, "showPoints": "never", "spanNulls": false, "stacking": {"group": "A", "mode": "none"}, "thresholdsStyle": {"mode": "off"}},
          "mappings": [],
          "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "red", "value": 90}]},
          "unit": "percent", "min": 0, "max": 100
        },
        "overrides": []
      },
      "gridPos": {"h": 8, "w": 12, "x": 12, "y": 15},
      "id": 5,
      "options": {"legend": {"calcs": ["mean", "max", "last"], "displayMode": "table", "placement": "bottom", "showLegend": true}, "tooltip": {"mode": "multi", "sort": "desc"}},
      "title": "메모리 사용률 (%)",
      "type": "timeseries",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "100 * (1 - node_memory_MemAvailable_bytes{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\", vmname=~\"$vmname\"} / node_memory_MemTotal_bytes{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\", vmname=~\"$vmname\"})",
          "legendFormat": "{{vm_namespace}}/{{vmname}}",
          "refId": "A"
        }
      ]
    },
    {
      "collapsed": false,
      "gridPos": {"h": 1, "w": 24, "x": 0, "y": 23},
      "id": 103,
      "title": "디스크 I/O",
      "type": "row"
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "palette-classic"},
          "custom": {"axisBorderShow": false, "axisColorMode": "text", "axisLabel": "", "axisPlacement": "auto", "barAlignment": 0, "drawStyle": "line", "fillOpacity": 10, "gradientMode": "none", "hideFrom": {"legend": false, "tooltip": false, "viz": false}, "lineInterpolation": "linear", "lineWidth": 1, "pointSize": 5, "scaleDistribution": {"type": "linear"}, "showPoints": "never", "spanNulls": false, "stacking": {"group": "A", "mode": "none"}, "thresholdsStyle": {"mode": "off"}},
          "mappings": [],
          "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}]},
          "unit": "Bps"
        },
        "overrides": []
      },
      "gridPos": {"h": 8, "w": 12, "x": 0, "y": 24},
      "id": 6,
      "options": {"legend": {"calcs": ["mean", "max", "last"], "displayMode": "table", "placement": "bottom", "showLegend": true}, "tooltip": {"mode": "multi", "sort": "desc"}},
      "title": "디스크 읽기 (Read)",
      "type": "timeseries",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "rate(node_disk_read_bytes_total{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\", vmname=~\"$vmname\"}[5m])",
          "legendFormat": "{{vm_namespace}}/{{vmname}} [{{device}}]",
          "refId": "A"
        }
      ]
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "palette-classic"},
          "custom": {"axisBorderShow": false, "axisColorMode": "text", "axisLabel": "", "axisPlacement": "auto", "barAlignment": 0, "drawStyle": "line", "fillOpacity": 10, "gradientMode": "none", "hideFrom": {"legend": false, "tooltip": false, "viz": false}, "lineInterpolation": "linear", "lineWidth": 1, "pointSize": 5, "scaleDistribution": {"type": "linear"}, "showPoints": "never", "spanNulls": false, "stacking": {"group": "A", "mode": "none"}, "thresholdsStyle": {"mode": "off"}},
          "mappings": [],
          "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}]},
          "unit": "Bps"
        },
        "overrides": []
      },
      "gridPos": {"h": 8, "w": 12, "x": 12, "y": 24},
      "id": 7,
      "options": {"legend": {"calcs": ["mean", "max", "last"], "displayMode": "table", "placement": "bottom", "showLegend": true}, "tooltip": {"mode": "multi", "sort": "desc"}},
      "title": "디스크 쓰기 (Write)",
      "type": "timeseries",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "rate(node_disk_written_bytes_total{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\", vmname=~\"$vmname\"}[5m])",
          "legendFormat": "{{vm_namespace}}/{{vmname}} [{{device}}]",
          "refId": "A"
        }
      ]
    },
    {
      "collapsed": false,
      "gridPos": {"h": 1, "w": 24, "x": 0, "y": 32},
      "id": 104,
      "title": "네트워크 I/O",
      "type": "row"
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "palette-classic"},
          "custom": {"axisBorderShow": false, "axisColorMode": "text", "axisLabel": "", "axisPlacement": "auto", "barAlignment": 0, "drawStyle": "line", "fillOpacity": 10, "gradientMode": "none", "hideFrom": {"legend": false, "tooltip": false, "viz": false}, "lineInterpolation": "linear", "lineWidth": 1, "pointSize": 5, "scaleDistribution": {"type": "linear"}, "showPoints": "never", "spanNulls": false, "stacking": {"group": "A", "mode": "none"}, "thresholdsStyle": {"mode": "off"}},
          "mappings": [],
          "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}]},
          "unit": "Bps"
        },
        "overrides": []
      },
      "gridPos": {"h": 8, "w": 12, "x": 0, "y": 33},
      "id": 8,
      "options": {"legend": {"calcs": ["mean", "max", "last"], "displayMode": "table", "placement": "bottom", "showLegend": true}, "tooltip": {"mode": "multi", "sort": "desc"}},
      "title": "네트워크 수신 (RX)",
      "type": "timeseries",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "rate(node_network_receive_bytes_total{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\", vmname=~\"$vmname\", device!=\"lo\"}[5m])",
          "legendFormat": "{{vm_namespace}}/{{vmname}} [{{device}}]",
          "refId": "A"
        }
      ]
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "palette-classic"},
          "custom": {"axisBorderShow": false, "axisColorMode": "text", "axisLabel": "", "axisPlacement": "auto", "barAlignment": 0, "drawStyle": "line", "fillOpacity": 10, "gradientMode": "none", "hideFrom": {"legend": false, "tooltip": false, "viz": false}, "lineInterpolation": "linear", "lineWidth": 1, "pointSize": 5, "scaleDistribution": {"type": "linear"}, "showPoints": "never", "spanNulls": false, "stacking": {"group": "A", "mode": "none"}, "thresholdsStyle": {"mode": "off"}},
          "mappings": [],
          "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}]},
          "unit": "Bps"
        },
        "overrides": []
      },
      "gridPos": {"h": 8, "w": 12, "x": 12, "y": 33},
      "id": 9,
      "options": {"legend": {"calcs": ["mean", "max", "last"], "displayMode": "table", "placement": "bottom", "showLegend": true}, "tooltip": {"mode": "multi", "sort": "desc"}},
      "title": "네트워크 송신 (TX)",
      "type": "timeseries",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "rate(node_network_transmit_bytes_total{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\", vmname=~\"$vmname\", device!=\"lo\"}[5m])",
          "legendFormat": "{{vm_namespace}}/{{vmname}} [{{device}}]",
          "refId": "A"
        }
      ]
    },
    {
      "collapsed": false,
      "gridPos": {"h": 1, "w": 24, "x": 0, "y": 41},
      "id": 105,
      "title": "시스템 부하 (Load Average)",
      "type": "row"
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "palette-classic"},
          "custom": {"axisBorderShow": false, "axisColorMode": "text", "axisLabel": "", "axisPlacement": "auto", "barAlignment": 0, "drawStyle": "line", "fillOpacity": 10, "gradientMode": "none", "hideFrom": {"legend": false, "tooltip": false, "viz": false}, "lineInterpolation": "linear", "lineWidth": 1, "pointSize": 5, "scaleDistribution": {"type": "linear"}, "showPoints": "never", "spanNulls": false, "stacking": {"group": "A", "mode": "none"}, "thresholdsStyle": {"mode": "off"}},
          "mappings": [],
          "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}]},
          "unit": "short"
        },
        "overrides": []
      },
      "gridPos": {"h": 8, "w": 24, "x": 0, "y": 42},
      "id": 10,
      "options": {"legend": {"calcs": ["mean", "max", "last"], "displayMode": "table", "placement": "bottom", "showLegend": true}, "tooltip": {"mode": "multi", "sort": "desc"}},
      "title": "Load Average (1m / 5m / 15m)",
      "type": "timeseries",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "node_load1{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\", vmname=~\"$vmname\"}",
          "legendFormat": "{{vm_namespace}}/{{vmname}} load1",
          "refId": "A"
        },
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "node_load5{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\", vmname=~\"$vmname\"}",
          "legendFormat": "{{vm_namespace}}/{{vmname}} load5",
          "refId": "B"
        },
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "node_load15{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\", vmname=~\"$vmname\"}",
          "legendFormat": "{{vm_namespace}}/{{vmname}} load15",
          "refId": "C"
        }
      ]
    },
    {
      "collapsed": false,
      "gridPos": {"h": 1, "w": 24, "x": 0, "y": 50},
      "id": 106,
      "title": "파일시스템",
      "type": "row"
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "thresholds"},
          "custom": {"align": "auto", "cellOptions": {"type": "auto"}, "filterable": true, "inspect": false},
          "mappings": [],
          "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "yellow", "value": 70}, {"color": "red", "value": 90}]}
        },
        "overrides": [
          {"matcher": {"id": "byName", "options": "사용률 (%)"}, "properties": [{"id": "custom.cellOptions", "value": {"type": "color-background"}}, {"id": "thresholds", "value": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "yellow", "value": 70}, {"color": "red", "value": 90}]}}]},
          {"matcher": {"id": "byName", "options": "Total"}, "properties": [{"id": "unit", "value": "bytes"}]},
          {"matcher": {"id": "byName", "options": "Used"}, "properties": [{"id": "unit", "value": "bytes"}]},
          {"matcher": {"id": "byName", "options": "Available"}, "properties": [{"id": "unit", "value": "bytes"}]}
        ]
      },
      "gridPos": {"h": 8, "w": 24, "x": 0, "y": 51},
      "id": 11,
      "options": {"cellHeight": "sm", "footer": {"countRows": false, "reducer": ["sum"], "show": false}, "showHeader": true},
      "title": "파일시스템 사용 현황",
      "transformations": [
        {"id": "merge", "options": {}},
        {
          "id": "organize",
          "options": {
            "renameByName": {
              "vm_namespace": "네임스페이스",
              "vmname": "VM 이름",
              "device": "디바이스",
              "mountpoint": "마운트 포인트",
              "Value #A": "Total",
              "Value #B": "Used",
              "Value #C": "Available",
              "Value #D": "사용률 (%)"
            }
          }
        }
      ],
      "type": "table",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "node_filesystem_size_bytes{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\", vmname=~\"$vmname\", fstype!~\"tmpfs|devtmpfs\"}",
          "instant": true,
          "legendFormat": "",
          "refId": "A"
        },
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "node_filesystem_size_bytes{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\", vmname=~\"$vmname\", fstype!~\"tmpfs|devtmpfs\"} - node_filesystem_free_bytes{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\", vmname=~\"$vmname\", fstype!~\"tmpfs|devtmpfs\"}",
          "instant": true,
          "legendFormat": "",
          "refId": "B"
        },
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "node_filesystem_avail_bytes{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\", vmname=~\"$vmname\", fstype!~\"tmpfs|devtmpfs\"}",
          "instant": true,
          "legendFormat": "",
          "refId": "C"
        },
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "100 * (1 - node_filesystem_avail_bytes{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\", vmname=~\"$vmname\", fstype!~\"tmpfs|devtmpfs\"} / node_filesystem_size_bytes{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\", vmname=~\"$vmname\", fstype!~\"tmpfs|devtmpfs\"})",
          "instant": true,
          "legendFormat": "",
          "refId": "D"
        }
      ]
    }
  ]
}
NEDASHEOF

    {
        printf 'apiVersion: grafana.integreatly.org/v1beta1\n'
        printf 'kind: GrafanaDashboard\n'
        printf 'metadata:\n'
        printf '  name: poc-vm-node-exporter\n'
        printf '  namespace: %s\n' "${NS}"
        printf '  labels:\n'
        printf '    app: poc-grafana\n'
        printf 'spec:\n'
        printf '  instanceSelector:\n'
        printf '    matchLabels:\n'
        printf '      dashboards: poc-grafana\n'
        printf '  json: |\n'
        sed 's/^/    /' /tmp/poc-vm-node-exporter-dashboard.json
    } > /tmp/poc-vm-node-exporter-dashboard.yaml

    oc apply -f /tmp/poc-vm-node-exporter-dashboard.yaml
    print_ok "GrafanaDashboard poc-vm-node-exporter 배포 완료"
    print_info "  대시보드: Grafana → Dashboards → VM OS 메트릭 (node_exporter / COO)"
}

print_summary() {
    local grafana_route
    grafana_route=$(oc get route poc-grafana-route -n "$NS" \
        -o jsonpath='{.spec.host}' 2>/dev/null || echo "")

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  완료! 모니터링 실습 환경이 준비되었습니다.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    if [ "${GRAFANA_INSTALLED:-false}" = "true" ]; then
        if [ -n "$grafana_route" ]; then
            echo -e "  Grafana URL : ${CYAN}https://${grafana_route}${NC}"
            echo -e "  계정        : admin / ${GRAFANA_ADMIN_PASS:-grafana123}"
            echo -e "  VM 대시보드 : ${CYAN}https://${grafana_route}/d/poc-vm-overview${NC}"
            echo -e "  OS 대시보드 : ${CYAN}https://${grafana_route}/d/poc-vm-node-exporter${NC}"
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
    step_dashboard
    step_vm
    step_coo
    step_coo_dashboard
    print_summary
}

main
