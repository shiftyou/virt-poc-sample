# Fence Agents Remediation (FAR) 구성

## 개요

FAR(Fence Agents Remediation)은 노드 장애 시 IPMI/BMC를 통해 물리 노드를 강제 재시작하여
클러스터의 안정성을 유지합니다.

Node Health Check Operator와 함께 사용하면 자동으로 장애 노드를 감지하고 복구합니다.

---

## 사전 조건

- FAR Operator 설치 완료 (`00-operators/03-far-operator.md` 참조)
- 각 워커 노드에 IPMI/BMC 접근 가능
- `setup.sh`에서 Fence Agent 정보 입력 (FENCE_AGENT_IP, FENCE_AGENT_USER, FENCE_AGENT_PASS)

---

## 적용 방법

```bash
# 프로젝트 루트에서
source env.conf

cd 01-environment/far

# FAR Template 및 설정 적용
envsubst < far-config.yaml | oc apply -f -

# 또는 apply.sh 사용
./apply.sh
```

---

## 파일 설명

| 파일 | 설명 |
|------|------|
| `far-config.yaml` | FenceAgentsRemediationTemplate 정의 |
| `consoleYamlSample.yaml` | Console에서 직접 적용 가능한 샘플 |
| `apply.sh` | envsubst 변수 치환 후 적용 |

---

## 상태 확인

```bash
# FAR Template 확인
oc get fenceagentsremediationtemplate -n openshift-workload-availability

# FAR 인스턴스 확인 (장애 발생 시 자동 생성)
oc get fenceagentsremediation -A

# FAR 상세 상태 확인
oc describe fenceagentsremediation -A

# Fence Agent Pod 상태 확인
oc get pods -n openshift-workload-availability | grep fence
```

---

## IPMI 연결 테스트

```bash
# IPMI 연결 테스트 (ipmitool 필요)
ipmitool -I lanplus \
  -H ${FENCE_AGENT_IP} \
  -U ${FENCE_AGENT_USER} \
  -P ${FENCE_AGENT_PASS} \
  chassis power status

# 지원하는 fence agent 목록 확인
oc exec -n openshift-workload-availability \
  deployment/fence-agents-remediation-operator-controller-manager \
  -- fence_ipmilan --help
```

---

## 수동 Fencing 테스트

```bash
# 특정 노드를 수동으로 fence (주의: 노드가 재시작됨)
oc apply -f - <<EOF
apiVersion: fence-agents-remediation.medik8s.io/v1alpha1
kind: FenceAgentsRemediation
metadata:
  name: test-fencing
  namespace: openshift-workload-availability
spec:
  nodeName: ${TEST_NODE}
  agent: fence_ipmilan
  sharedparameters:
    --ip: "${FENCE_AGENT_IP}"
    --username: "${FENCE_AGENT_USER}"
    --password: "${FENCE_AGENT_PASS}"
    --lanplus: ""
    --action: "reboot"
EOF
```

---

## 트러블슈팅

```bash
# FAR Operator 로그 확인
oc logs -n openshift-workload-availability \
  deployment/fence-agents-remediation-operator-controller-manager

# FAR 이벤트 확인
oc get events -n openshift-workload-availability --sort-by='.lastTimestamp'

# IPMI 포트 연결 테스트
nc -zv ${FENCE_AGENT_IP} 623
```
