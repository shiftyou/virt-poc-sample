# Grafana 구성

## 개요

Grafana를 배포하여 OpenShift Virtualization의 VM 메트릭을 시각화합니다.
OpenShift의 Prometheus를 데이터 소스로 연결하여 VM CPU, Memory, Network, Storage 메트릭을 모니터링합니다.

---

## 사전 조건

- `setup.sh`에서 Grafana 정보 입력 (GRAFANA_ADMIN_PASS)

---

## 적용 방법

```bash
# 프로젝트 루트에서
source env.conf

cd 01-environment/grafana

# Grafana 배포
envsubst < grafana-deploy.yaml | oc apply -f -
envsubst < grafana-datasource.yaml | oc apply -f -
oc apply -f grafana-dashboard-cm.yaml

# 또는 apply.sh 사용
./apply.sh
```

---

## Prometheus 데이터 소스 연결

OpenShift의 내장 Prometheus에 접근하려면 ServiceAccount 토큰이 필요합니다:

```bash
# Grafana ServiceAccount에 Prometheus 접근 권한 부여
oc adm policy add-cluster-role-to-user cluster-monitoring-view \
  -z grafana-serviceaccount -n poc-grafana

# Prometheus 접근 토큰 확인
oc serviceaccounts get-token grafana-serviceaccount -n poc-grafana
```

---

## 상태 확인

```bash
# Grafana Pod 상태 확인
oc get pods -n poc-grafana

# Grafana Route 확인
oc get route grafana -n poc-grafana

# Grafana 접속 URL
GRAFANA_URL=$(oc get route grafana -n poc-grafana -o jsonpath='{.spec.host}')
echo "Grafana URL: https://${GRAFANA_URL}"
echo "Username: admin"
echo "Password: ${GRAFANA_ADMIN_PASS}"
```

---

## VM 메트릭 확인

Grafana 접속 후 VM 관련 메트릭을 확인할 수 있습니다:

```promql
# VM CPU 사용률
kubevirt_vmi_cpu_usage_seconds_total

# VM 메모리 사용량
kubevirt_vmi_memory_used_bytes

# VM 네트워크 수신 바이트
kubevirt_vmi_network_receive_bytes_total

# VM 네트워크 송신 바이트
kubevirt_vmi_network_transmit_bytes_total

# VM 디스크 읽기 바이트
kubevirt_vmi_storage_read_traffic_bytes_total

# VM 디스크 쓰기 바이트
kubevirt_vmi_storage_write_traffic_bytes_total

# 실행 중인 VM 수
count(kubevirt_vmi_phase_count{phase="Running"})

# 노드별 VM 분포
count by (node) (kubevirt_vmi_phase_count{phase="Running"})
```

---

## CPU / Memory 상태 확인

```bash
# Grafana Pod 리소스 사용량
oc adm top pod -n poc-grafana

# 클러스터 전체 VM 리소스 사용량 (Prometheus 쿼리)
# oc exec -n openshift-monitoring prometheus-k8s-0 -- \
#   curl -s 'http://localhost:9090/api/v1/query?query=sum(kubevirt_vmi_cpu_usage_seconds_total)'
```

---

## 트러블슈팅

```bash
# Grafana 로그 확인
oc logs -n poc-grafana deployment/grafana

# Prometheus 연결 테스트
PROM_TOKEN=$(oc serviceaccounts get-token grafana-serviceaccount -n poc-grafana 2>/dev/null || echo "")
curl -H "Authorization: Bearer ${PROM_TOKEN}" \
  https://thanos-querier.openshift-monitoring.svc:9091/api/v1/query?query=up \
  -k
```
