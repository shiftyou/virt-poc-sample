# 모니터링 실습 (OpenShift Console / COO / Grafana / Dell / Hitachi)

OpenShift Virtualization 환경의 통합 모니터링 구성입니다.

---

## 1. OpenShift Console (Observe → Metrics)

OpenShift 내장 Prometheus(user-workload)를 통해 별도 툴 없이 콘솔에서 바로 VM 메트릭을 조회합니다.

### 사전 조건

- 네임스페이스에 user-workload 모니터링 레이블 설정:

```bash
oc label namespace poc-monitoring openshift.io/cluster-monitoring=true --overwrite
```

- `monitoring.coreos.com/v1` ServiceMonitor 등록 (10-monitoring.sh 실행 시 자동 생성)

### 메트릭 조회

1. OpenShift Console → **Observe → Metrics**
2. 상단 `Project` 드롭다운에서 `poc-monitoring` 선택
3. PromQL 입력:

```promql
# VM node_exporter 메모리 여유량
node_memory_MemAvailable_bytes{job="poc-monitoring-vm"}

# VM CPU 사용률
rate(node_cpu_seconds_total{job="poc-monitoring-vm",mode!="idle"}[5m])

# VM 디스크 읽기 속도
rate(node_disk_read_bytes_total{job="poc-monitoring-vm"}[5m])
```

### 알림 규칙 확인

OpenShift Console → **Observe → Alerting** → `poc-monitoring` 프로젝트에서
PrometheusRule로 정의한 알림(`VMNotRunning`, `VMHighMemoryUsage`) 상태를 확인합니다.

### ServiceMonitor 상태 확인

```bash
oc get servicemonitor.monitoring.coreos.com -n poc-monitoring
oc get endpoints poc-monitoring-node-exporter -n poc-monitoring
```

---

## 2. Grafana 대시보드

Grafana Operator를 통해 Grafana 인스턴스를 배포하고 OpenShift Monitoring(Prometheus)에 연동합니다.

### 사전 조건

- Grafana Operator 설치 (`00-operator/grafana-operator.md` 참조)
- `env.conf`의 `GRAFANA_ADMIN_PASS` 설정

### Grafana 인스턴스 배포

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

### OpenShift Prometheus DataSource 연동

```bash
# Grafana가 Prometheus를 읽을 수 있도록 ClusterRoleBinding 생성
oc create clusterrolebinding grafana-cluster-monitoring-view \
  --clusterrole=cluster-monitoring-view \
  --serviceaccount=poc-monitoring:poc-grafana-sa 2>/dev/null || true

# Prometheus 토큰 획득
TOKEN=$(oc create token poc-grafana-sa -n poc-monitoring --duration=8760h)

# GrafanaDatasource 생성
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

### OpenShift Virtualization 대시보드 배포

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

### Grafana 접속

```bash
# Route 확인
oc get route -n poc-monitoring | grep grafana

# 접속 URL 출력
echo "https://$(oc get route poc-grafana-route -n poc-monitoring \
  -o jsonpath='{.spec.host}')"
```

---

## 3. Cluster Observability Operator (COO)

COO는 네임스페이스 범위의 Prometheus/Alertmanager 스택을 `MonitoringStack` CR로 배포합니다.
클러스터 전역 Prometheus 없이 독립적인 모니터링 범위를 구성하고, VM의 node_exporter 메트릭을
수집하는 전체 흐름을 실습합니다.

```
poc-monitoring-vm (VM)
  └─ node_exporter :9100 (VM 내부)
       └─ virt-launcher Pod (masquerade NAT)
            └─ Service: poc-monitoring-node-exporter
                 ├─ ServiceMonitor (monitoring.rhobs/v1)    → COO Prometheus
                 └─ ServiceMonitor (monitoring.coreos.com/v1) → OpenShift Console
```

### 사전 조건

- Cluster Observability Operator 설치 (OperatorHub → "Cluster Observability Operator")
- OpenShift Virtualization 설치 (`env.conf`의 `VIRT_INSTALLED=true`)
- poc Template 등록 (`01-template/01-template.sh` 실행)
- `env.conf`의 `COO_INSTALLED=true` 설정

---

### 3-1. poc 템플릿으로 VM 생성

```bash
VM_NAME="poc-monitoring-vm"
NS="poc-monitoring"

# poc 템플릿으로 VM 생성
oc process -n openshift poc -p NAME="$VM_NAME" > ${VM_NAME}.yaml
oc apply -n "$NS" -f ${VM_NAME}.yaml

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
}'

# VM 시작
virtctl start "$VM_NAME" -n "$NS"

# 상태 확인
oc get vmi "$VM_NAME" -n "$NS"
```

VM이 Running 상태가 되면 VM 내부에 node_exporter를 설치합니다.

```bash
# VM 콘솔 접근
virtctl console "$VM_NAME" -n "$NS"

# VM 내부에서 node_exporter 설치 (09-node-exporter/node-exporter-install.sh 참조)
```

---

### 3-2. node-exporter Service 생성

virt-launcher Pod(`monitor=metrics`)를 셀렉터로 지정하여 VM 내부 node_exporter(9100)에 접근합니다.
masquerade 네트워크에서 Pod 포트가 VM 포트로 NAT 됩니다.

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

Endpoints 확인:

```bash
oc get endpoints poc-monitoring-node-exporter -n poc-monitoring
```

---

### 3-3. MonitoringStack 배포

`resourceSelector`의 레이블(`monitoring.rhobs/stack: poc-monitoring-stack`)이 붙은
ServiceMonitor / PrometheusRule / PodMonitor를 자동으로 수집합니다.

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

배포 확인:

```bash
oc get monitoringstack -n poc-monitoring
oc get pods -n poc-monitoring -l app.kubernetes.io/name=prometheus
oc get pods -n poc-monitoring -l app.kubernetes.io/name=alertmanager
```

---

### 3-4. ServiceMonitor 생성

#### COO용 ServiceMonitor (`monitoring.rhobs/v1`)

`monitoring.rhobs/stack` 레이블로 MonitoringStack의 Prometheus와 연결됩니다.

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

#### OpenShift Console용 ServiceMonitor (`monitoring.coreos.com/v1`)

OpenShift Console의 **Observe → Metrics** 탭에서 메트릭을 조회하려면
`monitoring.coreos.com/v1` ServiceMonitor와 네임스페이스 레이블이 필요합니다.

```bash
# 네임스페이스에 user-workload 모니터링 레이블 추가
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

ServiceMonitor 목록 확인:

```bash
# COO용
oc get servicemonitor.monitoring.rhobs -n poc-monitoring

# OpenShift Console용
oc get servicemonitor.monitoring.coreos.com -n poc-monitoring
```

---

### 3-5. PrometheusRule (VM 알림 규칙)

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
            summary: "VM이 Running 상태가 아닙니다"
            description: "VM {{ $labels.name }} 상태: {{ $labels.phase }}"
        - alert: VMHighMemoryUsage
          expr: >
            (kubevirt_vmi_memory_resident_bytes /
             (kubevirt_vmi_memory_resident_bytes + kubevirt_vmi_memory_available_bytes)) > 0.9
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "VM 메모리 사용률 90% 초과"
            description: "VM {{ $labels.name }} 의 메모리 사용률이 높습니다."
EOF
```

---

### 3-6. COO Prometheus 접근

COO MonitoringStack이 배포한 Prometheus는 클러스터 내부 서비스이므로,
아래 두 가지 방법으로 직접 조회할 수 있습니다.
OpenShift Console에서 보는 방법은 **1. OpenShift Console (Observe → Metrics)** 섹션을 참조하세요.

#### 방법 1 — Grafana 대시보드

Grafana와 COO를 함께 배포한 경우, COO Prometheus가 DataSource로 등록됩니다.

1. Grafana Route로 접속: `oc get route -n poc-monitoring`
2. **Explore** → DataSource: `COO-Prometheus` 선택
3. PromQL 입력 후 쿼리

```bash
# Grafana DataSource 등록 (COO Prometheus)
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

#### 방법 2 — Port-forward (COO Prometheus 직접 접근)

```bash
# Prometheus UI
oc port-forward svc/prometheus-operated 9090:9090 -n poc-monitoring
# 브라우저: http://localhost:9090

# Alertmanager UI
oc port-forward svc/alertmanager-operated 9093:9093 -n poc-monitoring
# 브라우저: http://localhost:9093
```

Prometheus UI에서:
- **Graph** → PromQL 직접 쿼리
- **Targets** → ServiceMonitor가 등록한 scrape 대상 확인
- **Alerts** → PrometheusRule로 정의한 알림 상태 확인

---

### 3-7. 전체 상태 확인

```bash
# MonitoringStack
oc get monitoringstack -n poc-monitoring

# 배포된 Pod 전체
oc get pods -n poc-monitoring

# ServiceMonitor (COO)
oc get servicemonitor.monitoring.rhobs -n poc-monitoring

# ServiceMonitor (console)
oc get servicemonitor.monitoring.coreos.com -n poc-monitoring

# PrometheusRule
oc get prometheusrule -n poc-monitoring

# VM 상태
oc get vmi poc-monitoring-vm -n poc-monitoring
```

---

## 4. Dell 스토리지 모니터링

Dell PowerStore / PowerFlex 스토리지를 OpenShift Monitoring과 연동합니다.

### Dell CSI PowerStore — 메트릭 수집

Dell CSI Driver는 Prometheus 메트릭 엔드포인트를 제공합니다.

```bash
# Dell CSI PowerStore metrics 서비스 확인
oc get service -n powerstore -l app=powerstore-metrics

# ServiceMonitor 등록 (CSI Driver가 배포된 네임스페이스)
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

### Dell PowerFlex (VxFlex OS) 모니터링

```bash
# PowerFlex SDC 메트릭 수집
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

### Dell 스토리지 Grafana 대시보드

Dell GitHub에서 공식 대시보드를 가져옵니다:

```bash
# Dell CSI 공식 대시보드 (JSON 임포트)
# https://github.com/dell/karavi-observability/tree/main/grafana/dashboards

# Grafana UI에서 임포트:
# Dashboards → Import → Upload JSON file
# 또는 Dashboard ID 입력 (Grafana.com 검색: dell csi)
```

주요 모니터링 항목:
- 스토리지 용량 및 사용률
- I/O 처리량 및 지연시간
- 볼륨별 IOPS

---

## 5. Hitachi 스토리지 모니터링

Hitachi VSP 시리즈를 OpenShift Monitoring과 연동합니다.

### Hitachi Ops Center API 연동

Hitachi VSP는 REST API를 제공합니다. Prometheus exporter로 메트릭을 수집합니다.

```bash
# Hitachi Storage Exporter 배포
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
          image: quay.io/poc/hitachi-exporter:latest   # 실제 이미지로 변경
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

# ServiceMonitor 등록
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

### Hitachi 모니터링 주요 항목

| 항목 | API 경로 |
|------|---------|
| 스토리지 풀 사용률 | `/v1/objects/storagePools` |
| 볼륨(LU) IOPS | `/v1/objects/ldevs/{ldevId}/metrics` |
| 포트 처리량 | `/v1/objects/ports/{portId}/metrics` |
| 컨트롤러 상태 | `/v1/objects/controllers` |
| DP 풀 용량 | `/v1/objects/pools` |

```bash
# Hitachi REST API 직접 테스트
curl -u admin:<password> \
  https://<Hitachi_IP>/ConfigurationManager/v1/objects/storagesystems \
  -k | python3 -m json.tool
```

---

## 상태 확인

```bash
# Grafana Pod 상태
oc get pods -n poc-monitoring -l app=grafana

# Grafana Route 확인
oc get route -n poc-monitoring

# ServiceMonitor 목록
oc get servicemonitor -n poc-monitoring

# Prometheus Target 확인 (수집 대상)
# OpenShift Console → Observe → Targets
```

---

## 롤백

```bash
oc delete namespace poc-monitoring
```
