# Fence Agents Remediation (FAR) 실습

Node Health Check Operator가 비정상 노드를 감지하면
FAR이 IPMI/BMC를 통해 해당 노드를 강제 재시작(fencing)하여 자동 복구하는 실습입니다.

```
NHC (감지) → FenceAgentsRemediationTemplate (IPMI fencing)

1단계: 정상 상태
┌───────────────────────────┐     ┌──────────────┐
│  NODE1 (Ready)            │     │  NODE2       │
│  ● poc-far-vm-1 (Running) │     │  (여유 있음)  │
│  ● poc-far-vm-2 (Running) │     │              │
└───────────────────────────┘     └──────────────┘

2단계: NODE1 장애 시뮬레이션 (kubelet 중단)
┌───────────────────────────┐     ┌──────────────┐
│  NODE1 (NotReady)         │     │  NODE2       │
│  ✗ kubelet 중단           │     │  (여유 있음)  │
└───────────────────────────┘     └──────────────┘
         │
         ▼  NHC 감지 (unhealthy 조건 충족)
         ▼  FenceAgentsRemediation 생성
         ▼  IPMI/BMC → 물리 노드 전원 재시작

3단계: 복구 완료
┌───────────────────────────┐     ┌──────────────┐
│  NODE1 (Ready, 재부팅 후) │     │  NODE2       │
│  ● poc-far-vm-1 (Running) │     │  (여유 있음)  │
│  ● poc-far-vm-2 (Running) │     │              │
└───────────────────────────┘     └──────────────┘
```

---

## 사전 조건

- `01-template` 완료 — `poc` Template 및 DataSource 등록
- Fence Agents Remediation Operator 설치 (`00-operator/far-operator.md` 참조)
- Node Health Check Operator 설치 (`00-operator/nhc-operator.md` 참조)
- 워커 노드에 IPMI/BMC 접근 가능
- `env.conf`에 `FENCE_AGENT_IP`, `FENCE_AGENT_USER`, `FENCE_AGENT_PASS` 설정
- `15-far.sh` 실행 완료

---

## 구성 개요

| 리소스 | 역할 |
|--------|------|
| FenceAgentsRemediationTemplate | IPMI fencing 방법 정의 |
| NodeHealthCheck | 노드 상태 감지 + FAR 트리거 조건 |
| poc-far-vm-1, vm-2 | 복구 대상 VM (NODE1에 배치) |

---

## FAR vs SNR 비교

| 항목 | FAR | SNR |
|------|-----|-----|
| 복구 방법 | IPMI/BMC 전원 제어 | 노드 자가 재시작 |
| 외부 장비 필요 | 필요 (BMC) | 불필요 |
| 복구 신뢰성 | 높음 (하드웨어 수준) | 중간 (OS 수준) |
| 적용 환경 | 베어메탈 | 베어메탈 / 가상 |

---

## FenceAgentsRemediationTemplate

```yaml
apiVersion: fence-agents-remediation.medik8s.io/v1alpha1
kind: FenceAgentsRemediationTemplate
metadata:
  name: poc-far-template
  namespace: openshift-workload-availability
spec:
  template:
    spec:
      agent: fence_ipmilan
      sharedparameters:
        --ip: "<FENCE_AGENT_IP>"
        --username: "<FENCE_AGENT_USER>"
        --lanplus: ""
        --action: "reboot"
      nodeparameters:
        --ipport:
          <node-name>: "623"
```

`agent`: IPMI 환경에 따라 `fence_ipmilan`, `fence_idrac`, `fence_ilo` 등 선택

---

## NodeHealthCheck 설정

```yaml
apiVersion: remediation.medik8s.io/v1alpha1
kind: NodeHealthCheck
metadata:
  name: poc-far-nhc
spec:
  remediationTemplate:
    apiVersion: fence-agents-remediation.medik8s.io/v1alpha1
    kind: FenceAgentsRemediationTemplate
    name: poc-far-template
    namespace: openshift-workload-availability
  selector:
    matchExpressions:
      - key: node-role.kubernetes.io/worker
        operator: Exists
  unhealthyConditions:
    - type: Ready
      status: "False"
      duration: 300s
    - type: Ready
      status: Unknown
      duration: 300s
```

---

## 실습 확인

### 초기 상태 확인

```bash
# NHC 상태 확인
oc get nodehealthcheck poc-far-nhc

# FAR Template 확인
oc get fenceagentsremediationtemplate -n openshift-workload-availability

# VM 배치 확인
oc get vmi -n poc-far -o wide

# IPMI 연결 테스트
ipmitool -I lanplus -H ${FENCE_AGENT_IP} \
  -U ${FENCE_AGENT_USER} -P ${FENCE_AGENT_PASS} chassis power status
```

### 노드 장애 시뮬레이션

```bash
# TEST_NODE에서 kubelet 중단 (노드에서 직접 실행)
oc debug node/${TEST_NODE} -- chroot /host systemctl stop kubelet

# 노드 상태 확인 (NotReady로 변경 확인)
oc get nodes -w
```

### NHC → FAR 발동 확인

```bash
# NHC 상태 확인 (unhealthy 감지 여부)
oc get nodehealthcheck poc-far-nhc -o yaml | grep -A 20 status

# FenceAgentsRemediation CR 생성 확인 (NHC가 자동 생성)
oc get fenceagentsremediation -A

# FAR 이벤트 확인
oc get events -n openshift-workload-availability \
  --sort-by='.lastTimestamp' | grep -i remediat

# IPMI fencing 실행 확인
oc logs -n openshift-workload-availability \
  deployment/fence-agents-remediation-operator-controller-manager --tail=50
```

### 복구 후 확인

```bash
# 노드 복구 확인 (Ready 복귀)
oc get nodes

# VM 상태 확인 (재시작 후 Running 복귀)
oc get vmi -n poc-far -o wide

# FenceAgentsRemediation CR 자동 삭제 확인
oc get fenceagentsremediation -A
```

---

## 트러블슈팅

```bash
# FAR Operator 로그
oc logs -n openshift-workload-availability \
  deployment/fence-agents-remediation-operator-controller-manager --tail=50

# NHC Controller 로그
oc logs -n openshift-workload-availability \
  deployment/node-healthcheck-operator-controller-manager --tail=50

# FAR CR 상세 확인
oc describe fenceagentsremediation -A

# IPMI 직접 테스트
ipmitool -I lanplus -H ${FENCE_AGENT_IP} \
  -U ${FENCE_AGENT_USER} -P ${FENCE_AGENT_PASS} chassis power status

# 노드 reboot 이력 확인
oc debug node/${TEST_NODE} -- chroot /host last reboot | head -5
```

---

## 롤백

```bash
# NodeHealthCheck 삭제
oc delete nodehealthcheck poc-far-nhc

# FenceAgentsRemediationTemplate 삭제
oc delete fenceagentsremediationtemplate poc-far-template \
  -n openshift-workload-availability

# VM 및 네임스페이스 삭제
oc delete namespace poc-far
```
