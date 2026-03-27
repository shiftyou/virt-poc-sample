# Alert 생성 (PrometheusRule)

## 개요

PrometheusRule을 사용하여 커스텀 Alert 조건을 생성합니다.
VM의 CPU 과부하, 메모리 부족, 네트워크 이상 등의 조건에 대한 Alert를 설정합니다.

---

## 사전 조건

- OpenShift Monitoring (기본 포함)
- openshift-monitoring 네임스페이스의 Prometheus

---

## 적용 방법

```bash
source ../../env.conf
cd 02-tests/alerts
./apply.sh
```

---

## 상태 확인

```bash
# PrometheusRule 목록 확인
oc get prometheusrule -n poc-alerts

# Alert 규칙 확인
oc get prometheusrule poc-vm-alerts -n poc-alerts -o yaml

# Alertmanager에서 활성 Alert 확인
oc exec -n openshift-monitoring alertmanager-main-0 -- \
  amtool alert -o extended --alertmanager.url=http://localhost:9093

# Prometheus에서 직접 Alert 상태 확인
oc exec -n openshift-monitoring prometheus-k8s-0 -- \
  curl -s 'http://localhost:9090/api/v1/alerts' | python3 -m json.tool

# Alert 규칙 로드 상태 확인
oc exec -n openshift-monitoring prometheus-k8s-0 -- \
  curl -s 'http://localhost:9090/api/v1/rules' | python3 -m json.tool | grep -A5 "poc-"
```

---

## Alert 테스트

```bash
# CPU 과부하 Alert 테스트용 VM 생성 (CPU 부하 발생)
oc apply -f - <<EOF
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: test-cpu-vm
  namespace: poc-alerts
spec:
  running: true
  template:
    spec:
      domain:
        cpu:
          cores: 1
        devices:
          disks:
            - name: cloudinit
              disk:
                bus: virtio
        resources:
          requests:
            memory: 1Gi
      volumes:
        - name: cloudinit
          cloudInitNoCloud:
            userData: |
              #cloud-config
              runcmd:
                - "while true; do :; done &"
EOF

# Alert 발생 확인 (몇 분 후)
oc exec -n openshift-monitoring prometheus-k8s-0 -- \
  curl -s 'http://localhost:9090/api/v1/alerts' | python3 -m json.tool
```

---

## 트러블슈팅

```bash
# PrometheusRule 적용 오류 확인
oc describe prometheusrule poc-vm-alerts -n poc-alerts

# Prometheus가 규칙을 로드했는지 확인
oc logs -n openshift-monitoring prometheus-k8s-0 | grep -i "rule\|error"

# Alert 레이블 확인 (routing 설정에 맞는지 확인)
oc get prometheusrule poc-vm-alerts -n poc-alerts -o jsonpath='{.spec.groups[*].rules[*].labels}'
```
