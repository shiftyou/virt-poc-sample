# CPU Overcommit 배수 변경

## 개요

OpenShift Virtualization에서 VM의 CPU Overcommit 비율을 조정합니다.
CPU Overcommit을 사용하면 물리 CPU 코어보다 더 많은 가상 CPU를 VM에 할당할 수 있습니다.

---

## 개념

- **CPU Overcommit**: 물리 CPU 대비 VM CPU 할당 비율
- 기본값: 1:1 (overcommit 없음)
- 예: 4 물리 코어 노드에서 overcommit 4:1 설정 시 → VM에 최대 16 vCPU 할당 가능

---

## 적용 방법

```bash
source ../../env.conf
cd 01-environment/cpu-overcommit
./apply.sh
```

---

## 파일 설명

| 파일 | 설명 |
|------|------|
| [`namespace.yaml`](namespace.yaml) | poc-cpu-overcommit 네임스페이스 |
| [`kubevirt-config.yaml`](kubevirt-config.yaml) | KubeVirt cpuOvercommit 4배 + host-passthrough 설정 |
| [`apply.sh`](apply.sh) | 적용 스크립트 |

---

## KubeVirt 설정으로 CPU Overcommit 변경

```bash
# 현재 KubeVirt 설정 확인
oc get kubevirt kubevirt -n openshift-cnv -o yaml | grep -A10 "developerConfiguration"

# CPU Overcommit 비율 변경 (4배 overcommit 예시)
oc patch kubevirt kubevirt -n openshift-cnv --type=merge -p '
{
  "spec": {
    "configuration": {
      "developerConfiguration": {
        "cpuOvercommit": 4
      }
    }
  }
}'

# 변경 확인
oc get kubevirt kubevirt -n openshift-cnv \
  -o jsonpath='{.spec.configuration.developerConfiguration.cpuOvercommit}'
```

---

## 상태 확인

```bash
# KubeVirt 설정 확인
oc get kubevirt kubevirt -n openshift-cnv -o yaml

# 노드별 CPU 할당 현황
oc describe node <node-name> | grep -A5 "Allocated resources"

# VM CPU 할당 확인
oc get vmi -A -o custom-columns="NAME:.metadata.name,CPU:.spec.domain.cpu.cores,NODE:.status.nodeName"

# 노드 CPU 사용률 확인
oc adm top node
```

---

## VM에서 CPU 사용률 확인

```bash
# VM 내부에서 CPU 확인
oc exec -n <namespace> <virt-launcher-pod> -- nproc

# VM의 CPU 메트릭 확인
oc exec -n openshift-monitoring prometheus-k8s-0 -- \
  curl -s 'http://localhost:9090/api/v1/query?query=rate(kubevirt_vmi_cpu_usage_seconds_total[5m])' \
  | python3 -m json.tool
```

---

## 트러블슈팅

```bash
# KubeVirt 컴포넌트 상태 확인
oc get pods -n openshift-cnv

# KubeVirt 설정 적용 확인
oc describe kubevirt kubevirt -n openshift-cnv

# virt-handler 로그 확인 (노드별 CPU 설정)
oc logs -n openshift-cnv -l kubevirt.io=virt-handler --tail=50
```
