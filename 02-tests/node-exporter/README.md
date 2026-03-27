# Node Exporter 구성 및 확인

## 개요

OpenShift는 기본적으로 node-exporter를 포함한 모니터링 스택을 제공합니다.
Node Exporter를 통해 노드의 CPU, Memory, Network, Disk 메트릭을 수집합니다.

---

## 파일 설명

| 파일 | 설명 |
|------|------|
| [`node-exporter-servicemonitor.yaml`](node-exporter-servicemonitor.yaml) | User Workload Monitoring 활성화 + 노드 메트릭 Recording Rule |

---

## 기본 Node Exporter 확인

```bash
# node-exporter DaemonSet 확인
oc get daemonset node-exporter -n openshift-monitoring

# node-exporter Pod 확인 (각 노드마다 1개)
oc get pods -n openshift-monitoring -l app.kubernetes.io/name=node-exporter

# node-exporter 메트릭 확인
oc exec -n openshift-monitoring \
  $(oc get pod -n openshift-monitoring -l app.kubernetes.io/name=node-exporter \
  -o name | head -1) \
  -- curl -s http://localhost:9100/metrics | head -50
```

---

## 적용 방법

```bash
source ../../env.conf
cd 02-tests/node-exporter
oc apply -f node-exporter-servicemonitor.yaml
```

---

## 노드 메트릭 확인 (Prometheus 쿼리)

```bash
# Prometheus에서 노드 메트릭 쿼리
# 노드 CPU 사용률
curl -s 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)'

# 또는 oc exec으로 Prometheus에 쿼리
oc exec -n openshift-monitoring prometheus-k8s-0 -- \
  curl -s 'http://localhost:9090/api/v1/query?query=node_memory_MemFree_bytes' \
  | python3 -m json.tool
```

---

## 주요 노드 메트릭

```bash
# CPU 관련 메트릭
# node_cpu_seconds_total        : CPU 모드별 사용 시간
# node_load1, node_load5        : 시스템 로드 평균

# Memory 관련 메트릭
# node_memory_MemTotal_bytes    : 전체 메모리
# node_memory_MemFree_bytes     : 여유 메모리
# node_memory_MemAvailable_bytes: 사용 가능 메모리

# Disk 관련 메트릭
# node_filesystem_size_bytes    : 파일시스템 전체 크기
# node_filesystem_avail_bytes   : 파일시스템 여유 크기
# node_disk_read_bytes_total    : 디스크 읽기 바이트
# node_disk_written_bytes_total : 디스크 쓰기 바이트

# Network 관련 메트릭
# node_network_receive_bytes_total  : 네트워크 수신 바이트
# node_network_transmit_bytes_total : 네트워크 송신 바이트
```

---

## 노드 메트릭 모니터링 명령

```bash
# 실시간 노드 리소스 사용량
watch oc adm top node

# 노드별 CPU/Memory 사용량 상세 보기
oc describe node | grep -A5 "Allocated resources"

# 네트워크 인터페이스 통계 (노드에서)
oc debug node/<node-name> -- ip -s link

# 노드 디스크 사용량 (노드에서)
oc debug node/<node-name> -- df -h

# 노드 메모리 상세 (노드에서)
oc debug node/<node-name> -- free -h
```

---

## ServiceMonitor 커스텀 메트릭

사용자 네임스페이스에서 커스텀 메트릭을 수집하려면 `openshift-monitoring` 설정이 필요합니다:

```bash
# User workload monitoring 활성화
oc apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
EOF
```

---

## 트러블슈팅

```bash
# node-exporter 로그 확인
oc logs -n openshift-monitoring \
  -l app.kubernetes.io/name=node-exporter \
  --tail=50

# ServiceMonitor 확인
oc get servicemonitor -n openshift-monitoring | grep node

# Prometheus 타겟 확인 (node-exporter가 스크랩되는지)
oc exec -n openshift-monitoring prometheus-k8s-0 -- \
  curl -s 'http://localhost:9090/api/v1/targets' \
  | python3 -m json.tool | grep -A5 "node-exporter"
```
