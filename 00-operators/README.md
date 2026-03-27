# 00-operators: Operator 설치 가이드

이 디렉토리는 OpenShift Virtualization POC에 필요한 Operator 설치 가이드를 포함합니다.

> **Note:** Operator 설치는 OperatorHub를 통해 진행됩니다. airgap 환경에서는 미러 레지스트리가 구성된 상태여야 합니다.

---

## 설치 순서

1. [OpenShift Virtualization](./01-openshift-virtualization.md) - VM 생성/관리의 핵심
2. [OADP Operator](./02-oadp-operator.md) - VM 백업/복원
3. [Fence Agents Remediation](./03-far-operator.md) - 노드 장애 복구
4. [Self Node Remediation](./04-snr-operator.md) - 자동 노드 복구
5. [Descheduler](./05-descheduler-operator.md) - 워크로드 재배치

---

## 설치 확인

```bash
# 모든 Operator 상태 확인
oc get csv -A | grep -E "kubevirt|oadp|fence|remediation|descheduler"

# Operator 구독 상태 확인
oc get subscription -A
```
