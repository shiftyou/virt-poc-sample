#!/bin/bash
# =============================================================================
# 11-monitoring.sh
#
# Monitoring practice environment setup (Grafana + Cluster Observability Operator)
#   1. Create poc-monitoring namespace
#   2. Deploy Grafana instance (requires Grafana Operator)
#   3. Integrate Prometheus DataSource
#   4. Deploy poc template VM + node-exporter Service (requires COO + Virt)
#   5. Deploy COO MonitoringStack + ServiceMonitor + PrometheusRule (requires COO)
#
# Usage: ./11-monitoring.sh
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
    print_warn "Grafana Community Operator not installed — install using the procedure below then re-run setup.sh."
    echo ""
    echo -e "  ${CYAN}# 1. Install Grafana Operator (community) — scoped to poc-monitoring namespace${NC}"
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
    print_info "After installation, verify:"
    echo -e "  ${CYAN}oc get csv -n poc-monitoring | grep grafana${NC}"
    print_info "After installation, re-run setup.sh to update GRAFANA_INSTALLED=true."
    echo ""
}

preflight() {
    print_step "Pre-flight checks"

    if ! oc whoami &>/dev/null; then
        print_error "Not logged into OpenShift."
        exit 1
    fi
    print_ok "Cluster connection: $(oc whoami) @ $(oc whoami --show-server)"

    # Auto-detect from cluster CSV if not in env.conf
    if [ "${GRAFANA_INSTALLED:-false}" != "true" ]; then
        if oc get csv --all-namespaces --no-headers 2>/dev/null \
            | grep -qi "grafana-operator"; then
            GRAFANA_INSTALLED=true
            print_ok "Grafana Community Operator auto-detected (CSV)"
        fi
    fi

    if [ "${COO_INSTALLED:-false}" != "true" ]; then
        if oc get csv --all-namespaces --no-headers 2>/dev/null \
            | grep -qi "cluster-observability-operator"; then
            COO_INSTALLED=true
            print_ok "Cluster Observability Operator auto-detected (CSV)"
        fi
    fi

    if [ "${VIRT_INSTALLED:-false}" != "true" ]; then
        if oc get csv --all-namespaces --no-headers 2>/dev/null \
            | grep -qi "kubevirt-hyperconverged"; then
            VIRT_INSTALLED=true
            print_ok "OpenShift Virtualization auto-detected (CSV)"
        fi
    fi

    if [ "${GRAFANA_INSTALLED:-false}" != "true" ] && [ "${COO_INSTALLED:-false}" != "true" ]; then
        print_warn "Both Grafana Operator and Cluster Observability Operator are not installed → skipping."
        step_install_grafana_guide
        print_warn "  COO installation guide: 00-operator/coo-operator.md"
        exit 77
    fi

    if [ "${GRAFANA_INSTALLED:-false}" = "true" ]; then
        print_ok "Grafana Community Operator confirmed"
    else
        print_warn "Grafana Operator not installed — skipping Grafana steps."
        step_install_grafana_guide
    fi

    if [ "${COO_INSTALLED:-false}" = "true" ]; then
        print_ok "Cluster Observability Operator confirmed"
        if [ "${VIRT_INSTALLED:-false}" = "true" ]; then
            print_ok "OpenShift Virtualization confirmed — VM creation step will run."
        else
            print_warn "OpenShift Virtualization not installed — skipping VM creation step."
        fi
    else
        print_warn "Cluster Observability Operator not installed — skipping COO steps."
    fi
}

step_namespace() {
    print_step "1/5  Create namespace (${NS})"

    if oc get namespace "$NS" &>/dev/null; then
        local ns_phase
        ns_phase=$(oc get namespace "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

        if [ "$ns_phase" = "Terminating" ]; then
            print_warn "Namespace $NS is in Terminating state — waiting for deletion to complete..."
            local retries=36
            local i=0
            while [ "$i" -lt "$retries" ]; do
                if ! oc get namespace "$NS" &>/dev/null; then
                    print_ok "Namespace deletion complete"
                    break
                fi
                printf "  [%d/%d] Waiting for Terminating...\r" "$((i+1))" "$retries"
                sleep 5
                i=$((i+1))
            done
            echo ""

            if oc get namespace "$NS" &>/dev/null; then
                print_error "Namespace $NS is still in Terminating state."
                print_info "Manual check: oc get namespace $NS -o yaml"
                print_info "Force remove finalizer: oc patch namespace $NS -p '{\"metadata\":{\"finalizers\":[]}}' --type=merge"
                exit 1
            fi

            oc new-project "$NS" > /dev/null
            print_ok "Namespace $NS recreated"
        else
            print_ok "Namespace $NS already exists (Active) — skipping"
        fi
    else
        oc new-project "$NS" > /dev/null
        print_ok "Namespace $NS created"
    fi
}

step_grafana() {
    if [ "${GRAFANA_INSTALLED:-false}" != "true" ]; then
        return
    fi
    print_step "2/6  Deploy Grafana instance"

    local grafana_pass="${GRAFANA_ADMIN_PASS:-grafana123}"

    if oc get grafana poc-grafana -n "$NS" &>/dev/null; then
        print_ok "Grafana poc-grafana already exists — skipping"
    else
        cat > ./poc-grafana.yaml <<EOF
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
        oc apply -f ./poc-grafana.yaml
        print_ok "Grafana poc-grafana deployed (admin password: ${grafana_pass})"
    fi

    # Wait for Grafana Pod Ready
    print_info "Waiting for Grafana Pod to be ready..."
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
        printf "  [%d/%d] Waiting... (%s)\r" "$((i+1))" "$retries" "${ready:--}"
        sleep 5
        i=$((i+1))
    done
    echo ""

    # Create OpenShift Route (create Route directly instead of ingress)
    if oc get route poc-grafana-route -n "$NS" &>/dev/null; then
        print_ok "Route poc-grafana-route already exists — skipping"
    else
        cat > ./poc-grafana-route.yaml <<EOF
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
        oc apply -f ./poc-grafana-route.yaml
        print_ok "Route poc-grafana-route created"
    fi

    local grafana_url
    grafana_url=$(oc get route poc-grafana-route -n "$NS" \
        -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    [ -n "$grafana_url" ] && print_ok "Grafana URL: https://${grafana_url}"
    print_info "  Login: admin / ${grafana_pass}"

    # Wait for Grafana SA creation (Grafana Operator creates SA asynchronously)
    print_info "Waiting for ServiceAccount poc-grafana-sa to be created..."
    local sa_retries=24
    local si=0
    while [ "$si" -lt "$sa_retries" ]; do
        if oc get serviceaccount poc-grafana-sa -n "$NS" &>/dev/null; then
            print_ok "ServiceAccount poc-grafana-sa confirmed"
            break
        fi
        printf "  [%d/%d] Waiting for SA...\r" "$((si+1))" "$sa_retries"
        sleep 5
        si=$((si+1))
    done
    echo ""

    # Grant cluster-monitoring-view permission to Grafana SA (oc apply — idempotent)
    print_info "Configuring Prometheus access permissions..."
    cat > ./grafana-monitoring-crb.yaml <<EOF
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
    oc apply --server-side -f ./grafana-monitoring-crb.yaml
    print_ok "cluster-monitoring-view ClusterRoleBinding applied"
}

step_datasource() {
    if [ "${GRAFANA_INSTALLED:-false}" != "true" ]; then
        return
    fi
    print_step "3/6  Integrate Prometheus DataSource"

    # Verify ServiceAccount exists (waited in step_grafana, but ensure once more)
    if ! oc get serviceaccount poc-grafana-sa -n "$NS" &>/dev/null; then
        print_warn "ServiceAccount poc-grafana-sa not found — skipping DataSource step."
        print_info "Manual check: oc get sa -n ${NS}"
        return
    fi

    # Generate ServiceAccount token (retry 3 times)
    TOKEN=""
    local t=0
    while [ "$t" -lt 3 ] && [ -z "$TOKEN" ]; do
        TOKEN=$(oc create token poc-grafana-sa -n "$NS" --duration=8760h 2>/dev/null || true)
        [ -z "$TOKEN" ] && sleep 5
        t=$((t+1))
    done
    if [ -z "$TOKEN" ]; then
        print_warn "Grafana SA token creation failed — Grafana Pod may still be starting."
        print_info "Run manually: oc create token poc-grafana-sa -n ${NS} --duration=8760h"
        return
    fi

    cat > ./prometheus-datasource.yaml <<EOF
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
    oc apply -f ./prometheus-datasource.yaml
    print_ok "Prometheus DataSource integrated"
}

step_dashboard() {
    if [ "${GRAFANA_INSTALLED:-false}" != "true" ]; then
        return
    fi
    print_step "4/6  Deploy VM overall status dashboard"

    # Delete existing CR then recreate — prevents oc apply unchanged and ensures recovery after Grafana UI deletion
    if oc get grafanadashboard poc-vm-overview -n "$NS" &>/dev/null; then
        print_info "GrafanaDashboard poc-vm-overview: deleting existing CR and recreating..."
        oc delete grafanadashboard poc-vm-overview -n "$NS" --wait=false 2>/dev/null || true
        sleep 2
    fi

    # Dashboard JSON (use single-quoted heredoc to prevent $-expansion)
    cat > ./poc-vm-dashboard.json << 'DASHBOARD_EOF'
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
  "description": "OpenShift Virtualization overall VM operations monitoring",
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
        "label": "Datasource",
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
        "label": "Namespace",
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
        "label": "VM Name",
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
  "title": "KubeVirt VM Overall Status",
  "uid": "poc-vm-overview",
  "version": 1,
  "panels": [
    {
      "collapsed": false,
      "gridPos": {"h": 1, "w": 24, "x": 0, "y": 0},
      "id": 100,
      "title": "VM Status Summary",
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
      "title": "Running — Cluster Total",
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
      "title": "Paused — Cluster Total",
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
      "title": "Abnormal VMI (Pending / Failed) — Cluster Total",
      "type": "stat",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "sum(kubevirt_vmi_phase_count{phase!~\"Running|running|Paused|paused\"}) or vector(0)",
          "legendFormat": "Abnormal (Pending/Failed etc.)",
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
      "title": "Total Active VMI — Cluster Total",
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
      "title": "VM Inventory",
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
          {"matcher": {"id": "byName", "options": "Value"},    "properties": [{"id": "custom.hidden", "value": true}]},
          {"matcher": {"id": "byName", "options": "Time"},     "properties": [{"id": "custom.hidden", "value": true}]},
          {"matcher": {"id": "byName", "options": "__name__"}, "properties": [{"id": "custom.hidden", "value": true}]},
          {"matcher": {"id": "byName", "options": "job"},      "properties": [{"id": "custom.hidden", "value": true}]},
          {"matcher": {"id": "byName", "options": "instance"}, "properties": [{"id": "custom.hidden", "value": true}]},
          {"matcher": {"id": "byName", "options": "endpoint"}, "properties": [{"id": "custom.hidden", "value": true}]},
          {"matcher": {"id": "byName", "options": "service"},  "properties": [{"id": "custom.hidden", "value": true}]},
          {"matcher": {"id": "byName", "options": "pod"},      "properties": [{"id": "custom.hidden", "value": true}]},
          {"matcher": {"id": "byName", "options": "container"},"properties": [{"id": "custom.hidden", "value": true}]},
          {"matcher": {"id": "byName", "options": "namespace"}, "properties": [{"id": "displayName", "value": "Namespace"}]},
          {"matcher": {"id": "byName", "options": "name"},      "properties": [{"id": "displayName", "value": "VM Name"}]},
          {"matcher": {"id": "byName", "options": "node"},      "properties": [{"id": "displayName", "value": "Node"}]},
          {"matcher": {"id": "byName", "options": "ready"},     "properties": [{"id": "displayName", "value": "Ready Status"}]},
          {"matcher": {"id": "byName", "options": "os"},        "properties": [{"id": "displayName", "value": "OS"}]},
          {"matcher": {"id": "byName", "options": "workload"},  "properties": [{"id": "displayName", "value": "Workload"}]}
        ]
      },
      "gridPos": {"h": 10, "w": 24, "x": 0, "y": 6},
      "id": 5,
      "options": {
        "cellHeight": "sm",
        "footer": {"countRows": false, "fields": "", "reducer": ["sum"], "show": false},
        "showHeader": true,
        "sortBy": [{"desc": false, "displayName": "Namespace"}]
      },
      "title": "VM List (Cluster Total)",
      "transformations": [
        {"id": "merge", "options": {}}
      ],
      "type": "table",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "kubevirt_vmi_info",
          "instant": true,
          "format": "table",
          "legendFormat": "",
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
      "title": "CPU Utilization (vCPU seconds/s)",
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
      "title": "Memory",
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
      "title": "Memory Usage (Resident)",
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
      "title": "Memory Utilization (%)",
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
      "title": "Network I/O",
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
      "title": "Network Receive (RX)",
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
      "title": "Network Transmit (TX)",
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
      "title": "Storage I/O",
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
      "title": "Storage Read",
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
      "title": "Storage Write",
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

    # Create YAML wrapper (using bash variable ${NS})
    {
        printf 'apiVersion: grafana.integreatly.org/v1beta1\n'
        printf 'kind: GrafanaDashboard\n'
        printf 'metadata:\n'
        printf '  name: poc-vm-overview\n'
        printf '  namespace: %s\n' "${NS}"
        printf '  labels:\n'
        printf '    app: poc-grafana\n'
        printf 'spec:\n'
        printf '  resyncPeriod: 5m\n'
        printf '  instanceSelector:\n'
        printf '    matchLabels:\n'
        printf '      dashboards: poc-grafana\n'
        printf '  json: |\n'
        sed 's/^/    /' ./poc-vm-dashboard.json
    } > ./poc-vm-dashboard.yaml

    oc create -f ./poc-vm-dashboard.yaml
    print_ok "GrafanaDashboard poc-vm-overview deployed"

    # Wait for Grafana Operator synchronization (up to 90 seconds)
    print_info "  Waiting for Grafana dashboard synchronization..."
    local synced=false
    for i in $(seq 1 18); do
        sleep 5
        local conditions
        conditions=$(oc get grafanadashboard poc-vm-overview -n "${NS}" -o jsonpath='{.status.conditions[*].type}' 2>/dev/null || true)
        if echo "${conditions}" | grep -q "Synchronized"; then
            synced=true
            break
        fi
        printf "    Waiting... (%ds)\n" $((i * 5))
    done

    if [ "${synced}" = "true" ]; then
        print_ok "  Dashboard synchronization complete"
    else
        print_warn "  Synchronization could not be confirmed — check directly in Grafana (resyncPeriod: 5m)"
    fi
    print_info "  Dashboard: Grafana → Dashboards → KubeVirt VM Overall Status"
}

step_vm() {
    if [ "${COO_INSTALLED:-false}" != "true" ] || [ "${VIRT_INSTALLED:-false}" != "true" ]; then
        return
    fi
    print_step "5/6  Create poc template VM (${VM_NAME})"

    if ! oc get template poc -n openshift &>/dev/null; then
        print_warn "poc Template not found — run 01-template first. Skipping VM creation."
        return
    fi
    print_ok "poc Template confirmed"

    if ! command -v virtctl &>/dev/null; then
        print_warn "virtctl not found — skipping VM creation."
        return
    fi

    # Create VM
    if oc get vm "$VM_NAME" -n "$NS" &>/dev/null; then
        print_ok "VM $VM_NAME already exists — skipping"
    else
        oc process -n openshift poc -p NAME="$VM_NAME" > ./${VM_NAME}.yaml
        oc apply -n "$NS" -f ./${VM_NAME}.yaml
        print_ok "VM $VM_NAME created"
    fi

    # Propagate monitor=metrics label to virt-launcher Pod
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
    }' 2>/dev/null && print_ok "Label monitor=metrics configured" || true

    # Create node-exporter Service
    # Forward traffic from virt-launcher Pod (monitor=metrics) to node-exporter (9100) inside VM
    if oc get svc poc-monitoring-node-exporter -n "$NS" &>/dev/null; then
        print_ok "Service poc-monitoring-node-exporter already exists — skipping"
    else
        cat > ./poc-monitoring-vm-service.yaml <<EOF
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
        oc apply -f ./poc-monitoring-vm-service.yaml
        print_ok "Service poc-monitoring-node-exporter created"
    fi

    # Add user-workload monitoring label to namespace (OpenShift Console visibility)
    oc label namespace "$NS" openshift.io/cluster-monitoring=true --overwrite 2>/dev/null || true
    print_ok "user-workload monitoring label configured"

    # ServiceMonitor for OpenShift Console Observe tab (monitoring.coreos.com/v1)
    if oc get servicemonitor poc-vm-node-exporter-console -n "$NS" &>/dev/null; then
        print_ok "ServiceMonitor poc-vm-node-exporter-console already exists — skipping"
    else
        cat > ./poc-vm-servicemonitor-console.yaml <<EOF
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
        oc apply -f ./poc-vm-servicemonitor-console.yaml
        print_ok "ServiceMonitor poc-vm-node-exporter-console created (for OpenShift Console)"
    fi

    # Start VM
    virtctl start "$VM_NAME" -n "$NS" 2>/dev/null || true
    print_info "VM start requested — may take time to reach Running state."
    print_warn "node_exporter installation inside VM is required (refer to 09-node-exporter/node-exporter-install.sh)"
    print_info "  oc get vmi $VM_NAME -n $NS"
}

step_coo() {
    if [ "${COO_INSTALLED:-false}" != "true" ]; then
        return
    fi
    print_step "6/7  Configure Cluster Observability Operator (COO)"

    # Check MonitoringStack CRD
    if ! oc get crd monitoringstacks.monitoring.rhobs &>/dev/null; then
        print_warn "MonitoringStack CRD not found — COO is not fully installed."
        return
    fi
    print_ok "MonitoringStack CRD confirmed"

    # Create MonitoringStack
    if oc get monitoringstack poc-monitoring-stack -n "$NS" &>/dev/null; then
        print_ok "MonitoringStack poc-monitoring-stack already exists — skipping"
    else
        cat > ./poc-monitoring-stack.yaml <<EOF
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
        oc apply -f ./poc-monitoring-stack.yaml
        print_ok "MonitoringStack poc-monitoring-stack deployed"
    fi

    # ServiceMonitor for VM node-exporter (monitoring.rhobs/v1 — for COO)
    if [ "${VIRT_INSTALLED:-false}" = "true" ]; then
        if oc get servicemonitor.monitoring.rhobs poc-vm-node-exporter -n "$NS" &>/dev/null; then
            print_ok "ServiceMonitor poc-vm-node-exporter already exists — skipping"
        else
            cat > ./poc-vm-servicemonitor-coo.yaml <<EOF
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
            oc apply -f ./poc-vm-servicemonitor-coo.yaml
            print_ok "ServiceMonitor poc-vm-node-exporter created (COO only)"
        fi
    fi

    # PrometheusRule (VM alert rules)
    if oc get prometheusrule poc-vm-alerts -n "$NS" &>/dev/null; then
        print_ok "PrometheusRule poc-vm-alerts already exists — skipping"
    else
        cat > ./poc-vm-alerts.yaml <<EOF
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
            summary: "VM is not in Running state"
            description: "VM {{ \$labels.name }} state: {{ \$labels.phase }}"
        - alert: VMHighMemoryUsage
          expr: >
            (kubevirt_vmi_memory_resident_bytes /
             (kubevirt_vmi_memory_resident_bytes + kubevirt_vmi_memory_available_bytes)) > 0.9
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "VM memory usage exceeds 90%"
            description: "VM {{ \$labels.name }} has high memory usage."
EOF
        oc apply -f ./poc-vm-alerts.yaml
        print_ok "PrometheusRule poc-vm-alerts created"
    fi

    # Configure node_exporter scraping for VMIs across all namespaces
    print_info "Configuring node_exporter Service/ServiceMonitor for all cluster VMIs..."
    local vmi_ns_list
    vmi_ns_list=$(oc get vmi --all-namespaces --no-headers 2>/dev/null \
        | awk '{print $1}' | sort -u || true)

    if [ -z "$vmi_ns_list" ]; then
        print_warn "No running VMIs found — skipping per-namespace node_exporter configuration."
    else
        while IFS= read -r vmi_ns; do
            [ -z "$vmi_ns" ] && continue

            # Add monitor=metrics label to virt-launcher pods
            oc label pods -n "$vmi_ns" -l "kubevirt.io=virt-launcher" \
                monitor=metrics --overwrite 2>/dev/null || true

            # Headless Service — collect node_exporter (9100) directly from each pod
            cat > ./vm-ne-svc.yaml <<EOF
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
            oc apply -f ./vm-ne-svc.yaml

            # ServiceMonitor (monitoring.rhobs/v1 — COO only)
            cat > ./vm-ne-sm.yaml <<EOF
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
            oc apply -f ./vm-ne-sm.yaml

            print_ok "  [${vmi_ns}] Service + ServiceMonitor complete"
        done <<< "$vmi_ns_list"
    fi

    # Register COO Prometheus as additional DataSource in Grafana if installed together
    if [ "${GRAFANA_INSTALLED:-false}" = "true" ]; then
        print_info "Registering COO Prometheus as Grafana DataSource..."
        if oc get grafanadatasource coo-prometheus-datasource -n "$NS" &>/dev/null; then
            print_ok "GrafanaDatasource coo-prometheus-datasource already exists — skipping"
        else
            cat > ./coo-prometheus-datasource.yaml <<EOF
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
            oc apply -f ./coo-prometheus-datasource.yaml
            print_ok "GrafanaDatasource coo-prometheus-datasource registered"
        fi
    fi

    print_info "Waiting for MonitoringStack Pod to start..."
    local retries=12
    local i=0
    while [ $i -lt $retries ]; do
        local ready
        ready=$(oc get pods -n "$NS" -l app.kubernetes.io/name=prometheus \
            --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
        if [ "$ready" -ge 1 ]; then
            print_ok "COO Prometheus Pod running"
            break
        fi
        printf "  [%d/%d] Waiting for COO Prometheus...\r" "$((i+1))" "$retries"
        sleep 5
        i=$((i+1))
    done
    echo ""
}

step_coo_dashboard() {
    if [ "${GRAFANA_INSTALLED:-false}" != "true" ] || [ "${COO_INSTALLED:-false}" != "true" ]; then
        return
    fi
    print_step "7/7  Deploy VM OS Metrics Dashboard (COO-Prometheus / node_exporter)"

    # Delete existing CR then recreate
    if oc get grafanadashboard poc-vm-node-exporter -n "$NS" &>/dev/null; then
        print_info "GrafanaDashboard poc-vm-node-exporter: deleting existing CR and recreating..."
        oc delete grafanadashboard poc-vm-node-exporter -n "$NS" --wait=false 2>/dev/null || true
        sleep 2
    fi

    cat > ./poc-vm-node-exporter-dashboard.json << 'NEDASHEOF'
{
  "annotations": {"list": [{"builtIn": 1, "datasource": {"type": "grafana", "uid": "-- Grafana --"}, "enable": true, "hide": true, "iconColor": "rgba(0,211,255,1)", "name": "Annotations & Alerts", "type": "dashboard"}]},
  "description": "VM internal OS metrics (node_exporter) — COO-Prometheus based",
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
        "label": "Datasource",
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
        "label": "Namespace",
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
        "label": "VM Name",
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
  "title": "VM OS Metrics (node_exporter / COO)",
  "uid": "poc-vm-node-exporter",
  "version": 1,
  "panels": [
    {
      "collapsed": false,
      "gridPos": {"h": 1, "w": 24, "x": 0, "y": 0},
      "id": 100,
      "title": "VM Status Summary",
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
      "title": "VM Average CPU Utilization",
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
      "title": "VM Average Memory Utilization",
      "type": "stat",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "100 * (1 - avg(node_memory_MemAvailable_bytes{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\", vmname=~\"$vmname\"} / node_memory_MemTotal_bytes{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\", vmname=~\"$vmname\"}))",
          "legendFormat": "Memory %",
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
      "title": "CPU Utilization (%) — Per VM",
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
      "title": "Memory",
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
      "title": "Memory Usage (Used)",
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
      "title": "Memory Utilization (%)",
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
      "title": "Disk I/O",
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
      "title": "Disk Read",
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
      "title": "Disk Write",
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
      "title": "Network I/O",
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
      "title": "Network Receive (RX)",
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
      "title": "Network Transmit (TX)",
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
      "title": "System Load (Load Average)",
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
      "title": "Filesystem",
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
          {"matcher": {"id": "byName", "options": "Utilization (%)"}, "properties": [{"id": "custom.cellOptions", "value": {"type": "color-background"}}, {"id": "thresholds", "value": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "yellow", "value": 70}, {"color": "red", "value": 90}]}}]},
          {"matcher": {"id": "byName", "options": "Total"}, "properties": [{"id": "unit", "value": "bytes"}]},
          {"matcher": {"id": "byName", "options": "Used"}, "properties": [{"id": "unit", "value": "bytes"}]},
          {"matcher": {"id": "byName", "options": "Available"}, "properties": [{"id": "unit", "value": "bytes"}]}
        ]
      },
      "gridPos": {"h": 8, "w": 24, "x": 0, "y": 51},
      "id": 11,
      "options": {"cellHeight": "sm", "footer": {"countRows": false, "reducer": ["sum"], "show": false}, "showHeader": true},
      "title": "Filesystem Usage Status",
      "transformations": [
        {"id": "merge", "options": {}},
        {
          "id": "organize",
          "options": {
            "renameByName": {
              "vm_namespace": "Namespace",
              "vmname": "VM Name",
              "device": "Device",
              "mountpoint": "Mount Point",
              "Value #A": "Total",
              "Value #B": "Used",
              "Value #C": "Available",
              "Value #D": "Utilization (%)"
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
        printf '  resyncPeriod: 5m\n'
        printf '  instanceSelector:\n'
        printf '    matchLabels:\n'
        printf '      dashboards: poc-grafana\n'
        printf '  json: |\n'
        sed 's/^/    /' ./poc-vm-node-exporter-dashboard.json
    } > ./poc-vm-node-exporter-dashboard.yaml

    oc create -f ./poc-vm-node-exporter-dashboard.yaml
    print_ok "GrafanaDashboard poc-vm-node-exporter deployed"
    print_info "  Dashboard: Grafana → Dashboards → VM OS Metrics (node_exporter / COO)"
}

print_summary() {
    local grafana_route
    grafana_route=$(oc get route poc-grafana-route -n "$NS" \
        -o jsonpath='{.spec.host}' 2>/dev/null || echo "")

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  Done! Monitoring practice environment is ready.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    if [ "${GRAFANA_INSTALLED:-false}" = "true" ]; then
        if [ -n "$grafana_route" ]; then
            echo -e "  Grafana URL  : ${CYAN}https://${grafana_route}${NC}"
            echo -e "  Credentials  : admin / ${GRAFANA_ADMIN_PASS:-grafana123}"
            echo -e "  VM Dashboard : ${CYAN}https://${grafana_route}/d/poc-vm-overview${NC}"
            echo -e "  OS Dashboard : ${CYAN}https://${grafana_route}/d/poc-vm-node-exporter${NC}"
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
        echo -e "  Direct access to COO Prometheus (port-forward):"
        echo -e "    ${CYAN}oc port-forward svc/prometheus-operated 9090:9090 -n ${NS}${NC}"
        echo -e "    Browser: ${CYAN}http://localhost:9090${NC}"
        echo ""
    fi

    if [ "${VIRT_INSTALLED:-false}" = "true" ] && [ "${COO_INSTALLED:-false}" = "true" ]; then
        echo -e "  VM status:"
        echo -e "    ${CYAN}oc get vmi ${VM_NAME} -n ${NS}${NC}"
        echo -e "  OpenShift Console → Observe → Metrics:"
        echo -e "    ${CYAN}node_memory_MemAvailable_bytes{job=\"poc-monitoring-vm\"}${NC}"
        echo ""
    fi

    echo -e "  Check Pod status:"
    echo -e "    ${CYAN}oc get pods -n ${NS}${NC}"
    echo ""
    echo -e "  For details: refer to 10-monitoring.md"
    echo ""
}

# =============================================================================
# Cleanup
# =============================================================================
cleanup() {
    print_step "--cleanup: Delete 11-monitoring resources"
    oc delete project poc-monitoring --ignore-not-found 2>/dev/null || true
    oc delete clusterrolebinding grafana-cluster-monitoring-view --ignore-not-found 2>/dev/null || true
    print_ok "11-monitoring resources deleted"
}

main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Monitoring Practice Environment Setup${NC}"
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

[ "${1:-}" = "--cleanup" ] && { cleanup; exit 0; }
main
