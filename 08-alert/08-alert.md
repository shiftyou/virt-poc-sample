# VM Alert 실습

OpenShift Monitoring(Prometheus)을 활용하여 VM 상태에 대한 알림 규칙을 설정합니다.

```
Prometheus (OpenShift Monitoring)
  └─ PrometheusRule (Alert 규칙)
       └─ kubevirt_vmi_phase_count 등 VM 메트릭 감시
            └─ AlertManager → 알림 발송 (Email/Slack/PagerDuty)
```

---

## 사전 조건

- OpenShift Monitoring 활성화 (기본 포함)
- User-defined project monitoring 활성화 (사용자 네임스페이스 Alert 사용 시)
- `08-alert.sh` 실행 완료

---

## VM 생성 (Alert 테스트용)

`08-alert.sh` 실행 시 poc 템플릿으로 `poc-alert-vm`을 자동 생성합니다.
생성된 VM을 이용해 각 Alert 조건을 직접 유발하고 동작을 확인합니다.

```bash
# VM 상태 확인
oc get vm,vmi -n poc-alert

# VM 콘솔 접속
virtctl console poc-alert-vm -n poc-alert
```

---

## User-defined Project Monitoring 활성화

사용자 네임스페이스(poc-alert 등)에 PrometheusRule을 적용하려면 활성화 필요합니다.

```bash
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

## 주요 VM 메트릭

| 메트릭 | 설명 |
|--------|------|
| `kubevirt_vmi_phase_count` | VMI 단계별 개수 (Running/Pending/Failed 등) |
| `kubevirt_vmi_vcpu_seconds_total` | vCPU 사용 시간 |
| `kubevirt_vmi_network_traffic_bytes_total` | VM 네트워크 트래픽 |
| `kubevirt_vmi_storage_iops_total` | VM 스토리지 IOPS |
| `kubevirt_vmi_memory_available_bytes` | VM 사용 가능 메모리 |
| `kubevirt_vmi_migration_data_processed_bytes` | Migration 진행 데이터량 |

---

## PrometheusRule 예제 — VM 알림

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: poc-vm-alerts
  namespace: poc-alert
  labels:
    role: alert-rules
spec:
  groups:
    - name: poc-vm-availability
      interval: 30s
      rules:

        # VM이 Running 상태가 아닌 경우 (Failed/Unknown)
        - alert: VMNotRunning
          expr: |
            kubevirt_vmi_phase_count{phase=~"Failed|Unknown"} > 0
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "VM이 비정상 상태입니다"
            description: "네임스페이스 {{ $labels.namespace }}에서 {{ $labels.phase }} 상태의 VM이 {{ $value }}개 감지되었습니다."

        # VM이 Pending 상태로 5분 이상 대기 중
        - alert: VMStuckPending
          expr: |
            kubevirt_vmi_phase_count{phase="Pending"} > 0
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "VM이 Pending 상태로 대기 중입니다"
            description: "네임스페이스 {{ $labels.namespace }}에서 Pending 상태의 VM이 {{ $value }}개 있습니다."

        # Live Migration 실패
        - alert: VMLiveMigrationFailed
          expr: |
            increase(kubevirt_vmi_migration_phase_transition_time_seconds_count{phase="Failed"}[10m]) > 0
          labels:
            severity: warning
          annotations:
            summary: "VM Live Migration이 실패했습니다"
            description: "VM {{ $labels.vmi }}의 Live Migration이 실패했습니다."

    - name: poc-vm-resources
      interval: 60s
      rules:

        # VM 메모리 부족 (사용 가능 메모리 100MiB 미만)
        - alert: VMLowMemory
          expr: |
            kubevirt_vmi_memory_available_bytes < 100 * 1024 * 1024
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "VM 메모리가 부족합니다"
            description: "VM {{ $labels.name }} (네임스페이스: {{ $labels.namespace }})의 사용 가능 메모리가 {{ $value | humanize }}입니다."
```

---

## Alert 유발 방법

각 Alert 조건을 실제로 만들어 동작을 확인합니다.

---

### 1. VMNotRunning — VM을 Failed 상태로 유발

존재하지 않는 노드를 `nodeSelector`로 지정하면 VMI가 스케줄되지 못하고 **Failed** 상태가 됩니다.
`for: 2m` 조건이 충족되면 Alert이 발생합니다.

```bash
# 1) 존재하지 않는 노드 지정으로 패치
oc patch vm poc-alert-vm -n poc-alert --type=merge -p \
  '{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/hostname":"nonexistent-node"}}}}}'

# 2) VM 재시작 → VMI가 Pending→Failed 전환
virtctl restart poc-alert-vm -n poc-alert

# 3) VMI 상태 확인 (Failed 확인)
oc get vmi -n poc-alert

# 4) 2분 후 OpenShift Console → Observe → Alerting 에서 VMNotRunning 확인
```

**복구:**

```bash
oc patch vm poc-alert-vm -n poc-alert --type=json \
  -p '[{"op":"remove","path":"/spec/template/spec/nodeSelector"}]'
virtctl start poc-alert-vm -n poc-alert
```

---

### 2. VMStuckPending — VM을 Pending 상태로 유발

리소스(CPU/메모리) 요청량을 클러스터 용량보다 크게 설정하면 VMI가 **Pending** 상태에 머뭅니다.
`for: 5m` 조건이 충족되면 Alert이 발생합니다.

```bash
# 1) 과도한 메모리 요청으로 패치 (예: 9999Gi)
oc patch vm poc-alert-vm -n poc-alert --type=merge -p \
  '{"spec":{"template":{"spec":{"domain":{"resources":{"requests":{"memory":"9999Gi"}}}}}}}'

# 2) VM 재시작 → VMI가 Pending 상태에 머뭄
virtctl restart poc-alert-vm -n poc-alert

# 3) VMI 상태 확인 (Pending 확인)
oc get vmi -n poc-alert

# 4) 5분 후 Console → Observe → Alerting 에서 VMStuckPending 확인
```

**복구:**

```bash
oc patch vm poc-alert-vm -n poc-alert --type=merge -p \
  '{"spec":{"template":{"spec":{"domain":{"resources":{"requests":{"memory":"2Gi"}}}}}}}'
virtctl start poc-alert-vm -n poc-alert
```

---

### 3. VMLiveMigrationFailed — Live Migration 실패 유발

Migration 대상 노드가 없거나 리소스가 부족한 상태에서 강제로 Migration을 시도합니다.

```bash
# 1) VM이 Running 상태인지 확인
oc get vmi poc-alert-vm -n poc-alert

# 2) 모든 워커 노드에 taint 추가 (Migration 대상 없음)
for node in $(oc get nodes -l node-role.kubernetes.io/worker -o name); do
  oc adm taint node "${node#node/}" migration-test=blocked:NoSchedule --overwrite
done

# 3) Live Migration 시작 → Failed 전환
virtctl migrate poc-alert-vm -n poc-alert

# 4) Migration 상태 확인
oc get vmim -n poc-alert

# 5) 10분 이내 Console → Observe → Alerting 에서 VMLiveMigrationFailed 확인
```

**복구:**

```bash
for node in $(oc get nodes -l node-role.kubernetes.io/worker -o name); do
  oc adm taint node "${node#node/}" migration-test=blocked:NoSchedule-
done
```

---

### 4. VMLowMemory — VM 메모리 부족 유발

VM 내부에서 `stress` 도구로 메모리를 고갈시킵니다.
`kubevirt_vmi_memory_available_bytes < 100MiB` 상태가 `for: 5m` 지속되면 Alert이 발생합니다.

```bash
# 1) VM 콘솔 접속
virtctl console poc-alert-vm -n poc-alert

# 2) VM 내부에서 stress 설치 및 실행 (RHEL/CentOS)
sudo dnf install -y stress-ng
# VM에 할당된 메모리 - 100MiB 이상을 점유 (예: 1.8Gi VM이면 1700m 사용)
stress-ng --vm 1 --vm-bytes 1700m --timeout 600s &

# 3) 사용 가능 메모리 확인
free -m

# 4) 5분 후 Console → Observe → Alerting 에서 VMLowMemory 확인
```

**복구 (VM 내부):**

```bash
# stress-ng 종료
kill %1
# 또는
killall stress-ng
```

---

## Alert 적용 확인

```bash
# PrometheusRule 확인
oc get prometheusrule -n poc-alert

# Alert 상태 확인 (Prometheus UI)
# OpenShift Console → Observe → Alerting → Alert Rules

# 활성 Alert 확인
oc get -n openshift-monitoring prometheusrule -A | grep poc

# CLI로 활성 Alert 조회
oc exec -n openshift-monitoring prometheus-k8s-0 -- \
  curl -s http://localhost:9090/api/v1/alerts | \
  python3 -m json.tool | grep -A5 "VMNotRunning"
```

---

## AlertManager Receiver 설정 (Slack 예제)

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: alertmanager-main
  namespace: openshift-monitoring
stringData:
  alertmanager.yaml: |
    global:
      slack_api_url: 'https://hooks.slack.com/services/YOUR/SLACK/WEBHOOK'
    route:
      receiver: slack-notifications
      group_by: ['alertname', 'namespace']
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 1h
    receivers:
      - name: slack-notifications
        slack_configs:
          - channel: '#ocp-alerts'
            title: '[{{ .Status | toUpper }}] {{ .CommonAnnotations.summary }}'
            text: '{{ .CommonAnnotations.description }}'
            send_resolved: true
```

---

## 트러블슈팅

```bash
# PrometheusRule 문법 오류 확인
oc describe prometheusrule poc-vm-alerts -n poc-alert

# User Workload Monitoring 상태 확인
oc get pods -n openshift-user-workload-monitoring

# Prometheus가 Rule을 로드했는지 확인
oc exec -n openshift-user-workload-monitoring prometheus-user-workload-0 -- \
  curl -s http://localhost:9090/api/v1/rules | python3 -m json.tool | grep VMNotRunning

# AlertManager 상태 확인
oc get pods -n openshift-monitoring | grep alertmanager
```

---

## 롤백

```bash
oc delete prometheusrule poc-vm-alerts -n poc-alert
oc delete namespace poc-alert
```
