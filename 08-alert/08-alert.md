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
