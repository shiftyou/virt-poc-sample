# Descheduler 설정

## 개요

KubeDescheduler는 클러스터의 Pod 분배를 최적화합니다.
불균형하게 배치된 Pod를 재스케줄링하여 노드 간 균형을 유지합니다.

OpenShift Virtualization VM(VMI)도 Pod로 동작하므로, VM의 노드 분배 최적화에도 활용됩니다.

---

## 사전 조건

- Kube Descheduler Operator 설치 완료 (`00-operators/05-descheduler-operator.md` 참조)

---

## 적용 방법

```bash
source ../../env.conf
cd 02-tests/descheduler
./apply.sh
```

---

## 파일 설명

| 파일 | 설명 |
|------|------|
| [`namespace.yaml`](namespace.yaml) | poc-descheduler 네임스페이스 |
| [`kubedescheduler.yaml`](kubedescheduler.yaml) | KubeDescheduler CR (AffinityAndTaints·TopologyAndDuplicates·LifecycleAndUtilization) |
| [`apply.sh`](apply.sh) | 적용 스크립트 |

---

## Descheduler 전략

| 전략 | 설명 |
|------|------|
| `LowNodeUtilization` | 과부하 노드의 Pod를 저부하 노드로 이동 |
| `HighNodeUtilization` | 노드 자원 활용률 극대화 |
| `RemoveDuplicates` | 동일 노드의 중복 Pod 제거 |
| `RemovePodsHavingTooManyRestarts` | 재시작 횟수가 많은 Pod 제거 |
| `PodLifeTime` | 오래된 Pod 재시작 |

---

## 상태 확인

```bash
# KubeDescheduler 상태 확인
oc get kubedescheduler -n openshift-kube-descheduler-operator

# Descheduler Pod 상태 확인
oc get pods -n openshift-kube-descheduler-operator

# Descheduler 로그 (재스케줄링 이벤트 확인)
oc logs -n openshift-kube-descheduler-operator \
  deployment/descheduler --tail=100

# 노드별 Pod 분포 확인
oc get pods -A -o wide | awk '{print $8}' | sort | uniq -c | sort -rn

# VM 노드 분포 확인
oc get vmi -A -o custom-columns="NAME:.metadata.name,NODE:.status.nodeName"
```

---

## 테스트 방법

```bash
# 특정 노드에 Pod를 집중 배포 후 Descheduler가 재배치하는지 확인
# 1. 테스트 Pod 생성
oc apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-descheduler
  namespace: poc-descheduler
spec:
  replicas: 10
  selector:
    matchLabels:
      app: test-descheduler
  template:
    metadata:
      labels:
        app: test-descheduler
    spec:
      containers:
        - name: nginx
          image: nginx
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
EOF

# 2. Pod 분포 확인
oc get pods -n poc-descheduler -o wide

# 3. Descheduler 동작 확인 (로그)
oc logs -n openshift-kube-descheduler-operator deployment/descheduler -f
```

---

## 트러블슈팅

```bash
# Descheduler 이벤트 확인
oc get events -n openshift-kube-descheduler-operator --sort-by='.lastTimestamp'

# KubeDescheduler CR 상태 확인
oc describe kubedescheduler cluster -n openshift-kube-descheduler-operator

# Descheduler 설정 확인
oc get kubedescheduler cluster -n openshift-kube-descheduler-operator -o yaml
```
