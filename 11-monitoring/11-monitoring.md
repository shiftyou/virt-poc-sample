# Monitoring Practice (OpenShift Console / COO / Grafana / Dell / Hitachi)

Integrated monitoring configuration for an OpenShift Virtualization environment.

---

## OpenShift Monitoring vs Cluster Observability Operator (COO)

OpenShift has two independent Prometheus-based monitoring stacks.

| Item | OpenShift Monitoring | COO (MonitoringStack) |
|------|----------------------|----------------------|
| **Operator** | Built into OpenShift platform | Requires separate Operator installation |
| **Scope** | Entire cluster (+ user-workload) | Per namespace |
| **API** | `monitoring.coreos.com/v1` | `monitoring.rhobs/v1` |
| **Configuration** | ConfigMap (`cluster-monitoring-config`) | `MonitoringStack` CR |
| **Console integration** | Console → Observe → Metrics (direct display) | Not supported (port-forward or Grafana) |
| **Data isolation** | user-workload can be separated per namespace | Fully isolated per MonitoringStack |
| **Retention period** | Shared cluster configuration | Independent configuration per MonitoringStack |
| **Multi-tenancy** | Separate query permissions via RBAC | Separate Prometheus instances entirely |
| **Primary use case** | Common platform and app monitoring | Independent monitoring per team/project |

### Which one to choose?

- **OpenShift Monitoring (user-workload)** — Check directly in OpenShift Console without additional infrastructure.
  Suitable for single cluster, centralized monitoring.

- **COO MonitoringStack** — Deploy Prometheus independently per namespace.
  Suitable when per-team metric isolation, separate retention policies, or cluster Prometheus load distribution is needed.

- **Use both stacks together** (this POC configuration) — Secure visibility in OpenShift Console with `monitoring.coreos.com/v1` ServiceMonitor,
  while simultaneously collecting into COO Prometheus with `monitoring.rhobs/v1` ServiceMonitor.

```
[VM node_exporter]
      │
      ├─ Service (poc-monitoring-node-exporter)
      │       │
      │       ├─ ServiceMonitor (monitoring.coreos.com/v1)
      │       │       └─ OpenShift user-workload Prometheus
      │       │               └─ Console → Observe → Metrics
      │       │
      │       └─ ServiceMonitor (monitoring.rhobs/v1)
      │               └─ COO Prometheus (poc-monitoring-stack)
      │                       └─ Grafana / port-forward
```

---

## 1. OpenShift Console (Observe → Metrics)

Query VM metrics directly in the console without additional tools using OpenShift's built-in Prometheus (user-workload).

### Prerequisites

- Set user-workload monitoring label on namespace:

```bash
oc label namespace poc-monitoring openshift.io/cluster-monitoring=true --overwrite
```

- Register `monitoring.coreos.com/v1` ServiceMonitor (automatically created when 10-monitoring.sh is executed)

### Query Metrics

1. OpenShift Console → **Observe → Metrics**
2. Select `poc-monitoring` from the `Project` dropdown at the top
3. Enter PromQL:

```promql
# VM node_exporter available memory
node_memory_MemAvailable_bytes{job="poc-monitoring-vm"}

# VM CPU utilization
rate(node_cpu_seconds_total{job="poc-monitoring-vm",mode!="idle"}[5m])

# VM disk read speed
rate(node_disk_read_bytes_total{job="poc-monitoring-vm"}[5m])
```

### Check Alert Rules

In OpenShift Console → **Observe → Alerting** → `poc-monitoring` project,
check the status of alerts (`VMNotRunning`, `VMHighMemoryUsage`) defined by PrometheusRule.

### Check ServiceMonitor Status

```bash
oc get servicemonitor.monitoring.coreos.com -n poc-monitoring
oc get endpoints poc-monitoring-node-exporter -n poc-monitoring
```

---

## 2. Cluster Observability Operator (COO)

COO deploys a namespace-scoped Prometheus/Alertmanager stack via the `MonitoringStack` CR.
Practice the full workflow of configuring an independent monitoring scope without a cluster-wide Prometheus,
and collecting VM node_exporter metrics.

```
poc-monitoring-vm (VM)
  └─ node_exporter :9100 (inside VM)
       └─ virt-launcher Pod (masquerade NAT)
            └─ Service: poc-monitoring-node-exporter
                 ├─ ServiceMonitor (monitoring.rhobs/v1)    → COO Prometheus
                 └─ ServiceMonitor (monitoring.coreos.com/v1) → OpenShift Console
```

### Prerequisites

- Cluster Observability Operator installed (OperatorHub → "Cluster Observability Operator")
- OpenShift Virtualization installed (`VIRT_INSTALLED=true` in `env.conf`)
- poc Template registered (run `01-template/01-template.sh`)
- `COO_INSTALLED=true` set in `env.conf`

---

### 2-1. Create VM from poc template

```bash
VM_NAME="poc-monitoring-vm"
NS="poc-monitoring"

# Create VM from poc template
oc process -n openshift poc -p NAME="$VM_NAME" > ${VM_NAME}.yaml
oc apply -n "$NS" -f ${VM_NAME}.yaml

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
}'

# Start VM
virtctl start "$VM_NAME" -n "$NS"

# Check status
oc get vmi "$VM_NAME" -n "$NS"
```

When the VM is in Running state, install node_exporter inside the VM.

```bash
# Access VM console
virtctl console "$VM_NAME" -n "$NS"

# Install node_exporter inside VM (refer to 09-node-exporter/node-exporter-install.sh)
```

---

### 2-2. Create node-exporter Service

Specify the virt-launcher Pod (`monitor=metrics`) as the selector to access node_exporter (9100) inside the VM.
In masquerade networking, Pod port is NAT'd to VM port.

```bash
oc apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: poc-monitoring-node-exporter
  namespace: poc-monitoring
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
```

Check Endpoints:

```bash
oc get endpoints poc-monitoring-node-exporter -n poc-monitoring
```

---

### 2-3. Deploy MonitoringStack

Automatically collects ServiceMonitor / PrometheusRule / PodMonitor that have the `resourceSelector` label (`monitoring.rhobs/stack: poc-monitoring-stack`).

```bash
oc apply -f - <<'EOF'
apiVersion: monitoring.rhobs/v1alpha1
kind: MonitoringStack
metadata:
  name: poc-monitoring-stack
  namespace: poc-monitoring
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
```

Verify deployment:

```bash
oc get monitoringstack -n poc-monitoring
oc get pods -n poc-monitoring -l app.kubernetes.io/name=prometheus
oc get pods -n poc-monitoring -l app.kubernetes.io/name=alertmanager
```

---

### 2-4. Create ServiceMonitor

#### ServiceMonitor for COO (`monitoring.rhobs/v1`)

Connected to MonitoringStack's Prometheus via the `monitoring.rhobs/stack` label.

```bash
oc apply -f - <<'EOF'
apiVersion: monitoring.rhobs/v1
kind: ServiceMonitor
metadata:
  name: poc-vm-node-exporter
  namespace: poc-monitoring
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
```

#### ServiceMonitor for OpenShift Console (`monitoring.coreos.com/v1`)

To query metrics in OpenShift Console's **Observe → Metrics** tab,
a `monitoring.coreos.com/v1` ServiceMonitor and namespace label are required.

```bash
# Add user-workload monitoring label to namespace
oc label namespace poc-monitoring openshift.io/cluster-monitoring=true --overwrite

oc apply -f - <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: poc-vm-node-exporter-console
  namespace: poc-monitoring
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
```

Check ServiceMonitor list:

```bash
# For COO
oc get servicemonitor.monitoring.rhobs -n poc-monitoring

# For OpenShift Console
oc get servicemonitor.monitoring.coreos.com -n poc-monitoring
```

---

### 2-5. PrometheusRule (VM alert rules)

```bash
oc apply -f - <<'EOF'
apiVersion: monitoring.rhobs/v1
kind: PrometheusRule
metadata:
  name: poc-vm-alerts
  namespace: poc-monitoring
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
            summary: "VM is not in Running state"
            description: "VM {{ $labels.name }} state: {{ $labels.phase }}"
        - alert: VMHighMemoryUsage
          expr: >
            (kubevirt_vmi_memory_resident_bytes /
             (kubevirt_vmi_memory_resident_bytes + kubevirt_vmi_memory_available_bytes)) > 0.9
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "VM memory usage exceeds 90%"
            description: "VM {{ $labels.name }} has high memory usage."
EOF
```

---

### 2-6. View COO metrics

COO MonitoringStack's Prometheus is not directly integrated with OpenShift Console as a cluster internal service.
Instead, query metrics via **two routes**.

> **Key principle**
> - OpenShift Console only shows the `monitoring.coreos.com/v1` ServiceMonitor → **user-workload Prometheus** route
> - COO Prometheus (`monitoring.rhobs/v1`) is accessed outside Console via Grafana or port-forward
> - This POC attaches both types of ServiceMonitor to the same Service for **simultaneous collection from both**

```
[poc-monitoring-node-exporter Service]
         │
         ├─ monitoring.coreos.com/v1 ServiceMonitor
         │        └─ user-workload Prometheus (OpenShift built-in)
         │                 └─ Console → Observe → Metrics ✔ (Project: poc-monitoring)
         │
         └─ monitoring.rhobs/v1 ServiceMonitor
                  └─ COO Prometheus (prometheus-operated)
                           ├─ Grafana → COO-Prometheus DataSource ✔
                           └─ port-forward → http://localhost:9090 ✔
```

---

#### Method 1 — OpenShift Console (Observe → Metrics)

Query the same metrics in the console through **user-workload Prometheus** rather than COO Prometheus.
If the `monitoring.coreos.com/v1` ServiceMonitor (`poc-vm-node-exporter-console`) is already registered,
just follow the steps below.

**Query steps:**

1. Access OpenShift Console
2. **Project** dropdown at top → select `poc-monitoring`
3. Left menu → **Observe → Metrics**
4. Enter query in PromQL input and click **Run queries**:

```promql
# VM available memory
node_memory_MemAvailable_bytes{job="poc-monitoring-vm"}

# VM CPU utilization
rate(node_cpu_seconds_total{job="poc-monitoring-vm",mode!="idle"}[5m])

# VM disk read speed
rate(node_disk_read_bytes_total{job="poc-monitoring-vm"}[5m])
```

**Check alert rules:**

- **Observe → Alerting** → `poc-monitoring` project
- Check `VMNotRunning`, `VMHighMemoryUsage` alert status

**Verify prerequisites:**

```bash
# Check namespace label
oc get namespace poc-monitoring --show-labels | grep cluster-monitoring

# Verify ServiceMonitor registration
oc get servicemonitor.monitoring.coreos.com poc-vm-node-exporter-console -n poc-monitoring

# Verify Endpoints active (node_exporter must be running in VM)
oc get endpoints poc-monitoring-node-exporter -n poc-monitoring
```

> **When metrics are not visible**
> - If Endpoints are empty, node_exporter is not running in the VM → run `09-node-exporter/node-exporter-install.sh`
> - If user-workload-monitoring is disabled:
>   ```bash
>   oc get configmap cluster-monitoring-config -n openshift-monitoring -o yaml | grep enableUserWorkload
>   # If enableUserWorkload: true is absent, it needs to be enabled
>   ```

---

#### Method 2 — Grafana (COO Prometheus DataSource)

Query in Grafana through a DataSource directly connected to COO Prometheus.
`coo-prometheus-datasource` is automatically registered when `10-monitoring.sh` is executed.

**Verify DataSource registration:**

```bash
oc get grafanadatasource coo-prometheus-datasource -n poc-monitoring
```

**Manual creation if registration is needed:**

```bash
oc apply -f - <<'EOF'
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: coo-prometheus-datasource
  namespace: poc-monitoring
spec:
  instanceSelector:
    matchLabels:
      dashboards: poc-grafana
  datasource:
    name: COO-Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus-operated.poc-monitoring.svc.cluster.local:9090
    isDefault: false
    jsonData:
      timeInterval: 5s
EOF
```

**Access Grafana and query steps:**

```bash
# Check Grafana Route
oc get route -n poc-monitoring -l app=grafana -o jsonpath='{.items[0].spec.host}'
```

1. Access `https://<grafana-route>` → `admin` / `grafana123` (or env.conf value)
2. Left menu → **Explore**
3. DataSource dropdown at top → select **COO-Prometheus**
4. Enter PromQL in **Metrics browser** or directly:

```promql
# node_exporter metrics (COO Prometheus collected)
node_memory_MemAvailable_bytes{job="poc-monitoring-vm"}
rate(node_cpu_seconds_total{job="poc-monitoring-vm",mode!="idle"}[5m])
```

> **When DataSource connection fails**
> COO Prometheus Pod may still be starting up.
> ```bash
> oc get pods -n poc-monitoring -l app.kubernetes.io/name=prometheus
> # STATUS must be Running for Grafana to query successfully
> ```

**Note — Direct access to COO Prometheus via Port-forward:**

```bash
oc port-forward svc/prometheus-operated 9090:9090 -n poc-monitoring
# Browser: http://localhost:9090
# Targets tab → check poc-vm-node-exporter ServiceMonitor scrape targets
# Alerts tab → check VMNotRunning, VMHighMemoryUsage alert status
```

---

### 2-7. Check overall status

```bash
# MonitoringStack
oc get monitoringstack -n poc-monitoring

# All deployed Pods
oc get pods -n poc-monitoring

# ServiceMonitor (COO)
oc get servicemonitor.monitoring.rhobs -n poc-monitoring

# ServiceMonitor (console)
oc get servicemonitor.monitoring.coreos.com -n poc-monitoring

# PrometheusRule
oc get prometheusrule -n poc-monitoring

# VM status
oc get vmi poc-monitoring-vm -n poc-monitoring
```

---

## 3. Grafana Dashboard

Deploy a Grafana instance via Grafana Operator and integrate it with OpenShift Monitoring (Prometheus).

### Prerequisites

- Grafana Community Operator installed (see installation guide below)
- `GRAFANA_ADMIN_PASS` configured in `env.conf`

### Install Grafana Community Operator

Install the Grafana Operator from OperatorHub (community-operators) scoped to the `poc-monitoring` namespace.

```bash
# Create namespace (if it does not exist)
oc new-project poc-monitoring

# Install Grafana Operator (namespace-scoped)
oc apply -f - <<'EOF'
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
EOF

# Verify installation complete (wait for Succeeded status)
oc get csv -n poc-monitoring | grep grafana
# grafana-operator.v5.x.x   Grafana Operator   5.x.x   Succeeded

# Re-run setup.sh to update GRAFANA_INSTALLED=true
./setup.sh
```

### Deploy Grafana instance

```bash
source env.conf

oc apply -f - <<EOF
apiVersion: grafana.integreatly.org/v1beta1
kind: Grafana
metadata:
  name: poc-grafana
  namespace: poc-monitoring
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
      admin_password: ${GRAFANA_ADMIN_PASS}
  ingress:
    enabled: true
EOF
```

### Integrate OpenShift Prometheus DataSource

```bash
# Create ClusterRoleBinding so Grafana can read Prometheus
oc create clusterrolebinding grafana-cluster-monitoring-view \
  --clusterrole=cluster-monitoring-view \
  --serviceaccount=poc-monitoring:poc-grafana-sa 2>/dev/null || true

# Obtain Prometheus token
TOKEN=$(oc create token poc-grafana-sa -n poc-monitoring --duration=8760h)

# Create GrafanaDatasource
oc apply -f - <<EOF
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: prometheus-datasource
  namespace: poc-monitoring
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
```

### Deploy OpenShift Virtualization Dashboard

```bash
oc apply -f - <<'EOF'
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: kubevirt-dashboard
  namespace: poc-monitoring
spec:
  instanceSelector:
    matchLabels:
      dashboards: poc-grafana
  json: >
    {
      "title": "OpenShift Virtualization Overview",
      "panels": [
        {
          "title": "Running VMs",
          "type": "stat",
          "targets": [
            {
              "expr": "sum(kubevirt_vmi_phase_count{phase=\"Running\"})",
              "legendFormat": "Running VMs"
            }
          ]
        },
        {
          "title": "VM CPU Usage",
          "type": "graph",
          "targets": [
            {
              "expr": "rate(kubevirt_vmi_vcpu_seconds_total[5m])",
              "legendFormat": "{{name}}"
            }
          ]
        },
        {
          "title": "VM Memory Available",
          "type": "graph",
          "targets": [
            {
              "expr": "kubevirt_vmi_memory_available_bytes",
              "legendFormat": "{{name}}"
            }
          ]
        }
      ]
    }
EOF
```

### Access Grafana

A Route is automatically created when `11-monitoring.sh` is executed. For manual creation:

```bash
oc apply -f - <<'EOF'
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: poc-grafana-route
  namespace: poc-monitoring
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
```

```bash
# Print access URL
echo "https://$(oc get route poc-grafana-route -n poc-monitoring \
  -o jsonpath='{.spec.host}')"
```

**Check login credentials:**

```bash
# GRAFANA_ADMIN_PASS value from env.conf (default: grafana123)
oc get secret grafana-admin-credentials -n poc-monitoring \
  -o jsonpath='{.data.GF_SECURITY_ADMIN_USER}' | base64 -d && echo
oc get secret grafana-admin-credentials -n poc-monitoring \
  -o jsonpath='{.data.GF_SECURITY_ADMIN_PASSWORD}' | base64 -d && echo
```

---

### VM Status Monitoring

Monitor VM status with KubeVirt metrics in Grafana.
With Prometheus DataSource integrated, use the following PromQL in **Explore** or dashboards.

**Key metrics:**

```promql
# VM running state (number of Running VMs)
sum(kubevirt_vmi_phase_count{phase="Running"})

# CPU utilization per VM
rate(kubevirt_vmi_vcpu_seconds_total[5m])

# VM memory usage
kubevirt_vmi_memory_used_bytes

# VM available memory
kubevirt_vmi_memory_available_bytes

# VM network receive
rate(kubevirt_vmi_network_receive_bytes_total[5m])

# VM network transmit
rate(kubevirt_vmi_network_transmit_bytes_total[5m])

# VM disk read
rate(kubevirt_vmi_storage_read_traffic_bytes_total[5m])

# VM disk write
rate(kubevirt_vmi_storage_write_traffic_bytes_total[5m])

# Live Migration status
kubevirt_vmi_migration_phase_transition_time_from_creation_seconds
```

**Import official KubeVirt dashboard from Grafana.com:**

```bash
oc apply -f - <<'EOF'
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: kubevirt-overview
  namespace: poc-monitoring
spec:
  instanceSelector:
    matchLabels:
      dashboards: poc-grafana
  grafanaCom:
    id: 11625    # Official KubeVirt dashboard
EOF
```

Or import directly from Grafana UI:
1. **Dashboards → Import**
2. Enter **Grafana.com Dashboard ID**: `11625` then **Load**
3. Select DataSource: **Prometheus** → **Import**

**Check VM status in OpenShift Console (without Grafana):**

```bash
# Console > Virtualization > VirtualMachines > individual VM > Metrics tab
# Or CLI
oc get vmi -A
oc get vmim -A   # Live Migration status
```

---

## 4. Dell Storage Monitoring

Integrate Dell PowerStore / PowerFlex storage with OpenShift Monitoring.

### Dell CSI PowerStore — Metrics collection

Dell CSI Driver provides a Prometheus metrics endpoint.

```bash
# Check Dell CSI PowerStore metrics service
oc get service -n powerstore -l app=powerstore-metrics

# Register ServiceMonitor (namespace where CSI Driver is deployed)
oc apply -f - <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: dell-powerstore-metrics
  namespace: poc-monitoring
spec:
  namespaceSelector:
    matchNames:
      - powerstore
  selector:
    matchLabels:
      app: powerstore-metrics
  endpoints:
    - port: metrics
      interval: 30s
      path: /metrics
EOF
```

### Dell PowerFlex (VxFlex OS) Monitoring

```bash
# Collect PowerFlex SDC metrics
oc apply -f - <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: dell-powerflex-metrics
  namespace: poc-monitoring
spec:
  namespaceSelector:
    matchNames:
      - vxflexos
  selector:
    matchLabels:
      app.kubernetes.io/name: csi-powerflex
  endpoints:
    - port: metrics
      interval: 30s
      path: /metrics
EOF
```

### Dell Storage Grafana Dashboard

Import official dashboards from Dell GitHub:

```bash
# Dell CSI official dashboard (JSON import)
# https://github.com/dell/karavi-observability/tree/main/grafana/dashboards

# Import from Grafana UI:
# Dashboards → Import → Upload JSON file
# Or enter Dashboard ID (search Grafana.com: dell csi)
```

Key monitoring items:
- Storage capacity and utilization
- I/O throughput and latency
- IOPS per volume

---

## 5. Hitachi Storage Monitoring

Integrate Hitachi VSP series with OpenShift Monitoring.

### Hitachi Ops Center API Integration

Hitachi VSP provides a REST API. Collect metrics using a Prometheus exporter.

```bash
# Deploy Hitachi Storage Exporter
oc apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hitachi-storage-exporter
  namespace: poc-monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: hitachi-storage-exporter
  template:
    metadata:
      labels:
        app: hitachi-storage-exporter
    spec:
      containers:
        - name: exporter
          image: quay.io/poc/hitachi-exporter:latest   # Replace with actual image
          env:
            - name: HITACHI_HOST
              value: "<Hitachi_Ops_Center_IP>"
            - name: HITACHI_USER
              value: "admin"
            - name: HITACHI_PASS
              valueFrom:
                secretKeyRef:
                  name: hitachi-credentials
                  key: password
          ports:
            - name: metrics
              containerPort: 9101
EOF

# Register ServiceMonitor
oc apply -f - <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: hitachi-storage-metrics
  namespace: poc-monitoring
spec:
  selector:
    matchLabels:
      app: hitachi-storage-exporter
  endpoints:
    - port: metrics
      interval: 60s
      path: /metrics
EOF
```

### Hitachi Monitoring Key Items

| Item | API path |
|------|---------|
| Storage pool utilization | `/v1/objects/storagePools` |
| Volume (LU) IOPS | `/v1/objects/ldevs/{ldevId}/metrics` |
| Port throughput | `/v1/objects/ports/{portId}/metrics` |
| Controller status | `/v1/objects/controllers` |
| DP pool capacity | `/v1/objects/pools` |

```bash
# Test Hitachi REST API directly
curl -u admin:<password> \
  https://<Hitachi_IP>/ConfigurationManager/v1/objects/storagesystems \
  -k | python3 -m json.tool
```

---

## Status Check

```bash
# Grafana Pod status
oc get pods -n poc-monitoring -l app=grafana

# Check Grafana Route
oc get route -n poc-monitoring

# ServiceMonitor list
oc get servicemonitor -n poc-monitoring

# Check Prometheus Targets (scrape targets)
# OpenShift Console → Observe → Targets
```

---

## Rollback

```bash
oc delete namespace poc-monitoring
```
