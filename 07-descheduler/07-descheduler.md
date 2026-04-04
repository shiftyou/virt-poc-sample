# Descheduler 실습

KubeDescheduler가 노드 부하를 감지하여 VM을 자동으로 재배치하는 실습입니다.

```
1단계: VM 3개를 nodeSelector 없이 아무 노드에나 기동
┌──────────────────┐     ┌──────────────────────────────┐
│  NODE1           │     │  NODE2, ...                  │
│                  │     │                              │
│  (비어 있음)     │     │  ● vm-1   (배포됨)            │
│                  │     │  ● vm-2   (배포됨)            │
│                  │     │  ● vm-fixed (배포됨)          │
└──────────────────┘     └──────────────────────────────┘

2단계: 3개 VM을 NODE1으로 Live Migration (nodeSelector 임시 적용)
┌─────────────────────────────────┐     ┌──────────────┐
│  NODE1 (TEST_NODE)              │     │  NODE2, ...  │
│                                 │     │              │
│  ● vm-1        (250m CPU)       │     │  (여유 있음)  │
│  ● vm-2        (250m CPU)       │     │              │
│  ● vm-fixed    (250m CPU) [evict=false] │     │      │
│                                 │     │              │
│  Migration 완료 → nodeSelector 제거    │              │
└─────────────────────────────────┘     └──────────────┘

3단계: 트리거 VM을 NODE1에 배포 → CPU > 70% 초과
┌─────────────────────────────────┐     ┌──────────────┐
│  NODE1                          │     │  NODE2, ...  │
│                                 │     │              │
│  ● vm-1        (250m CPU)       │     │  (여유 있음)  │
│  ● vm-2        (250m CPU)       │     │              │
│  ● vm-fixed    (250m CPU) [evict=false] │     │      │
│  ● vm-trigger  (계산된 CPU)     │     │              │
│                                 │     │              │
│  CPU 사용률 > 70%  ← 임계값 초과 │     │              │
└─────────────────────────────────┘     └──────────────┘

4단계: Descheduler 발동 (60초 이내)
┌─────────────────────────────────┐     ┌──────────────────────┐
│  NODE1                          │     │  NODE2, ...          │
│                                 │     │                      │
│  ● vm-fixed   (annotation 보호) │     │  ● vm-1  (Migration) │
│  ● vm-trigger (최신 → 유지)     │     │  ● vm-2  (Migration) │
└─────────────────────────────────┘     └──────────────────────┘
```

---

## 사전 조건

- `01-template` 완료 — poc Template 및 DataSource 등록
- Kube Descheduler Operator 설치 (`00-operator/descheduler-operator.md` 참조)
- 워커 노드 2개 이상 (VM 재배치 대상 노드 필요)
- `06-descheduler.sh` 실행 완료

---

## 구성 개요

| VM | 노드 고정 | CPU request | descheduler 대상 | 이유 |
|----|----------|-------------|-----------------|------|
| poc-descheduler-vm-1 | NODE1 | 250m | ✅ 대상 | annotation 없음 |
| poc-descheduler-vm-2 | NODE1 | 250m | ✅ 대상 | annotation 없음 |
| poc-descheduler-vm-fixed | NODE1 | 250m | ❌ 제외 | `descheduler.alpha.kubernetes.io/evict: "false"` |
| poc-descheduler-vm-trigger | NODE1 | 계산된 값 | ✅ 잠재 대상 | 가장 나중에 배포 |

---

## KubeDescheduler 설정 내용

```yaml
apiVersion: operator.openshift.io/v1
kind: KubeDescheduler
metadata:
  name: cluster
  namespace: openshift-kube-descheduler-operator
spec:
  managementState: Managed
  deschedulingIntervalSeconds: 60
  profiles:
    - LifecycleAndUtilization
  profileCustomizations:
    devLowNodeUtilizationThresholds: High
    namespaces:
      included:
        - poc-descheduler
```

### High 임계값 의미

| 구분 | CPU | Memory | Pods |
|------|-----|--------|------|
| **underutilized** (이동 목적지) | < 40% | < 40% | < 40% |
| **overutilized** (이동 원점) | > 70% | > 70% | > 70% |

NODE1의 CPU requests 합계가 Allocatable의 **70% 초과** 시 → overutilized 판정 → vm-1, vm-2 Live Migration 발동

---

## Annotation — vm-fixed 보호 원리

```yaml
# VM spec.template.metadata.annotations
descheduler.alpha.kubernetes.io/evict: "false"
```

VM의 Pod 템플릿에 위 annotation을 추가하면 Descheduler가 해당 Pod를 evict 대상에서 제외합니다.

```bash
# 06-descheduler.sh 에서 적용되는 패치
oc patch vm poc-descheduler-vm-fixed -n poc-descheduler --type=merge -p '{
  "spec": {
    "template": {
      "metadata": {
        "annotations": {
          "descheduler.alpha.kubernetes.io/evict": "false"
        }
      }
    }
  }
}'
```

`descheduler.alpha.kubernetes.io/evict: "false"` → Descheduler가 vm-fixed의 virt-launcher Pod를 evict 대상에서 제외 → NODE1 유지

---

## 실습 확인

### 초기 상태 확인

```bash
# 모든 VM이 NODE1에 배치되어 있는지 확인
oc get vmi -n poc-descheduler -o wide

# NODE1 CPU request 현황
NODE1=$(oc get node -l node-role.kubernetes.io/worker \
  -o jsonpath='{.items[0].metadata.name}')

oc get pods --all-namespaces \
  --field-selector="spec.nodeName=${NODE1}" \
  -o jsonpath='{range .items[*]}{.metadata.name}: {.spec.containers[0].resources.requests.cpu}{"\n"}{end}'

# 노드별 리소스 현황
oc describe node $NODE1 | grep -A 10 "Allocated resources"
```

### Descheduler 동작 확인 (60초 대기)

```bash
# VM 노드 변화 실시간 모니터링
oc get vmi -n poc-descheduler -o wide --watch

# Descheduler 이벤트 확인
oc get events -n poc-descheduler \
  --field-selector reason=Evicted \
  --sort-by='.lastTimestamp'

# Descheduler 로그 확인
oc logs -n openshift-kube-descheduler-operator \
  deployment/descheduler --tail=50
```

### 예상 결과 확인

```bash
# vm-1, vm-2 → 다른 노드로 이동 확인
oc get vmi -n poc-descheduler -o \
  custom-columns=NAME:.metadata.name,NODE:.status.nodeName,PHASE:.status.phase

# NAME                          NODE      PHASE
# poc-descheduler-vm-1          worker-1  Running   ← 이동됨
# poc-descheduler-vm-2          worker-2  Running   ← 이동됨
# poc-descheduler-vm-fixed      worker-0  Running   ← 유지 (PDB)
# poc-descheduler-vm-trigger    worker-0  Running   ← 유지

# PDB 상태 확인
oc get pdb -n poc-descheduler
```

### Migration 이력 확인

```bash
# VirtualMachineInstanceMigration 기록
oc get vmim -n poc-descheduler

# Migration 상세
oc describe vmim -n poc-descheduler
```

---

## Descheduler 설정 확인 및 조정

```bash
# 현재 KubeDescheduler 설정 확인
oc get kubedescheduler cluster \
  -n openshift-kube-descheduler-operator -o yaml

# 인터벌 조정 (빠른 테스트용: 30초)
oc patch kubedescheduler cluster \
  -n openshift-kube-descheduler-operator \
  --type=merge \
  -p '{"spec":{"deschedulingIntervalSeconds":30}}'

# Descheduler Pod 재시작
oc rollout restart deployment/descheduler \
  -n openshift-kube-descheduler-operator
```

---

## 트러블슈팅

```bash
# Descheduler가 동작하지 않을 때
oc logs -n openshift-kube-descheduler-operator \
  deployment/descheduler | grep -E "evict|migrate|error|LowNode"

# VM evictionStrategy 확인
oc get vm -n poc-descheduler -o \
  jsonpath='{range .items[*]}{.metadata.name}: {.spec.template.spec.evictionStrategy}{"\n"}{end}'
# → 모두 LiveMigrate 이어야 함

# PDB 상태 확인 (vm-fixed만 있어야 함)
oc get pdb -n poc-descheduler

# 노드 taint 확인 (Migration 불가 원인)
oc get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
```

---

## 롤백

```bash
# KubeDescheduler 설정 초기화 (네임스페이스 제한 제거)
oc patch kubedescheduler cluster \
  -n openshift-kube-descheduler-operator \
  --type=merge \
  -p '{"spec":{"profileCustomizations":{"namespaces":null}}}'

# VM 및 네임스페이스 삭제
oc delete namespace poc-descheduler
```

---

## DevKubeVirtRelieveAndMigrate 프로필

`DevKubeVirtRelieveAndMigrate` 프로필을 사용할 경우, Descheduler가 PSI(Pressure Stall Information) 기반으로 노드 압력을 감지하여 VM을 자동 이동시킵니다.
이 프로필을 사용하려면 워커 노드에서 커널 파라미터 `psi=1`이 활성화되어 있어야 합니다.

아래 MachineConfig를 먼저 적용하세요:

```bash
oc apply -f - <<'EOF'
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: 99-openshift-machineconfig-worker-psi-karg
  labels:
    machineconfiguration.openshift.io/role: worker
spec:
  kernelArguments:
  - psi=1
EOF
```

> **주의**: MachineConfig 적용 시 Machine Config Operator가 워커 노드를 순차적으로 재시작(drain → reboot → uncordon)합니다.
> 모든 워커 노드 재시작이 완료된 후(`oc get mcp worker` 상태가 `UPDATED=True`) Descheduler를 구성하세요.

```bash
# MachineConfigPool 상태 확인 (UPDATED=True 될 때까지 대기)
oc get mcp worker -w

# KubeDescheduler에 DevKubeVirtRelieveAndMigrate 프로필 적용
oc patch kubedescheduler cluster \
  -n openshift-kube-descheduler-operator \
  --type=merge \
  -p '{"spec":{"profiles":["DevKubeVirtRelieveAndMigrate"]}}'
```
