# Node Exporter 실습

OpenShift에 내장된 node-exporter와 커스텀 메트릭 수집 방법을 설명합니다.

---

## OpenShift 내장 Node Exporter

OpenShift Monitoring은 **node-exporter를 기본 포함**합니다.
별도 설치 없이 모든 노드에 DaemonSet으로 배포되어 있습니다.

```bash
# 내장 node-exporter Pod 확인
oc get pods -n openshift-monitoring -l app.kubernetes.io/name=node-exporter

# 수집 중인 메트릭 확인 (예: 첫 번째 Pod)
NODE_EXPORTER_POD=$(oc get pods -n openshift-monitoring \
  -l app.kubernetes.io/name=node-exporter \
  -o jsonpath='{.items[0].metadata.name}')

oc exec -n openshift-monitoring "$NODE_EXPORTER_POD" -- \
  curl -s http://localhost:9100/metrics | grep node_cpu | head -10
```

### 주요 내장 메트릭

| 메트릭 | 설명 |
|--------|------|
| `node_cpu_seconds_total` | CPU 사용 시간 (mode별) |
| `node_memory_MemAvailable_bytes` | 사용 가능 메모리 |
| `node_filesystem_avail_bytes` | 파일시스템 여유 공간 |
| `node_network_receive_bytes_total` | 네트워크 수신 바이트 |
| `node_disk_io_time_seconds_total` | 디스크 I/O 시간 |
| `node_load1` / `node_load5` / `node_load15` | 시스템 Load Average |

---

## 커스텀 Node Exporter 추가

기본 node-exporter에 없는 메트릭을 수집하려면 별도 배포합니다.
OpenShift에서는 **Privileged** 설정이 필요합니다.

### 1. ServiceAccount + SCC 설정

```bash
oc create namespace poc-node-exporter

# ServiceAccount 생성
oc create serviceaccount node-exporter-sa -n poc-node-exporter

# privileged SCC 부여 (호스트 파일시스템 접근 필요)
oc adm policy add-scc-to-user privileged \
  -z node-exporter-sa -n poc-node-exporter
```

### 2. DaemonSet 배포

```bash
oc apply -f - <<'EOF'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: custom-node-exporter
  namespace: poc-node-exporter
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
```

### 3. Service + ServiceMonitor 등록

```bash
oc apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: custom-node-exporter
  namespace: poc-node-exporter
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
  namespace: poc-node-exporter
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
```

---

## textfile Collector — 커스텀 메트릭 수집

node-exporter의 `textfile` collector를 사용하면 스크립트로 생성한 메트릭을 수집할 수 있습니다.

### 예: VM 개수 메트릭 수집 스크립트

노드에서 실행되는 virt-launcher Pod 수를 수집하는 예제입니다.

```bash
# 메트릭 파일 생성 스크립트 (CronJob으로 주기 실행)
cat > /var/lib/node_exporter/textfile_collector/vm_count.prom << 'EOF'
# HELP node_vm_count Number of running VMs on this node
# TYPE node_vm_count gauge
node_vm_count $(crictl ps 2>/dev/null | grep -c virt-launcher || echo 0)
EOF
```

CronJob으로 주기 수집:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: vm-metrics-collector
  namespace: poc-node-exporter
spec:
  schedule: "*/1 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          hostPID: true
          tolerations:
            - operator: Exists
          containers:
            - name: collector
              image: registry.access.redhat.com/ubi9/ubi-minimal:latest
              command:
                - /bin/sh
                - -c
                - |
                  VM_COUNT=$(chroot /host crictl ps 2>/dev/null | grep -c virt-launcher || echo 0)
                  echo "# HELP node_vm_count Number of running VMs on this node"
                  echo "# TYPE node_vm_count gauge"
                  echo "node_vm_count ${VM_COUNT}" > /textfile/vm_count.prom
              securityContext:
                privileged: true
              volumeMounts:
                - name: textfile
                  mountPath: /textfile
                - name: host-root
                  mountPath: /host
          volumes:
            - name: textfile
              hostPath:
                path: /var/lib/node_exporter/textfile_collector
            - name: host-root
              hostPath:
                path: /
          restartPolicy: OnFailure
```

---

## 메트릭 확인

```bash
# node-exporter 메트릭 접근 (port-forward)
oc port-forward -n poc-node-exporter \
  daemonset/custom-node-exporter 9100:9100 &

curl http://localhost:9100/metrics | grep node_

# Prometheus에서 쿼리
# OpenShift Console → Observe → Metrics
# 쿼리: node_memory_MemAvailable_bytes
# 쿼리: node_cpu_seconds_total{mode="idle"}
```

---

## 트러블슈팅

```bash
# DaemonSet 상태 확인
oc get daemonset custom-node-exporter -n poc-node-exporter

# Pod 로그 확인
oc logs -n poc-node-exporter \
  -l app=custom-node-exporter --tail=30

# SCC 설정 확인
oc get pod -n poc-node-exporter \
  -o jsonpath='{.items[*].metadata.annotations.openshift\.io/scc}'

# ServiceMonitor 상태 확인
oc get servicemonitor -n poc-node-exporter
```

---

## 롤백

```bash
oc delete namespace poc-node-exporter
```
