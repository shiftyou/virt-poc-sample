# 모니터링 실습 (Grafana / Dell / Hitachi)

OpenShift Virtualization 환경의 통합 모니터링 구성입니다.

---

## 1. Grafana 대시보드

Grafana Operator를 통해 Grafana 인스턴스를 배포하고
OpenShift Monitoring(Prometheus)에 연동합니다.

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

## 2. Dell 스토리지 모니터링

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

## 3. Hitachi 스토리지 모니터링

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
