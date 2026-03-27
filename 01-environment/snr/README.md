# Self Node Remediation (SNR) 구성

## 개요

SNR(Self Node Remediation)은 노드 장애 시 해당 노드가 스스로 재시작하여 복구합니다.
IPMI 없이도 동작하며, 노드 간 통신을 통해 장애를 감지합니다.

FAR과 달리 외부 펜싱 장치가 없어도 사용 가능합니다.

---

## 사전 조건

- SNR Operator 설치 완료 (`00-operators/04-snr-operator.md` 참조)

---

## 적용 방법

```bash
# 프로젝트 루트에서
source env.conf

cd 01-environment/snr

# SNR 설정 적용
oc apply -f snr-config.yaml

# 또는 apply.sh 사용
./apply.sh
```

---

## 파일 설명

| 파일 | 설명 |
|------|------|
| `snr-config.yaml` | SelfNodeRemediationConfig + Template |
| `consoleYamlSample.yaml` | Console에서 직접 적용 가능한 샘플 |
| `apply.sh` | 적용 스크립트 |

---

## 상태 확인

```bash
# SNR DaemonSet 확인 (모든 노드에 배포됨)
oc get daemonset -n openshift-workload-availability | grep self-node

# SNR Pod 상태 확인 (각 노드에 1개씩)
oc get pods -n openshift-workload-availability | grep self-node

# SNR 설정 확인
oc get selfnoderemediationconfig -n openshift-workload-availability -o yaml

# SNR Template 확인
oc get selfnoderemediationtemplate -n openshift-workload-availability

# 활성화된 SNR 인스턴스 확인 (장애 발생 시 생성)
oc get selfnoderemediation -A
```

---

## SNR 동작 방식

1. Node Health Check Operator가 노드 장애를 감지
2. SNR Template을 참조하여 SelfNodeRemediation CR 생성
3. 장애 노드의 SNR DaemonSet Pod가 CR을 감지
4. 노드가 스스로 재시작 (reboot)
5. 재시작 후 정상 상태 복구

---

## 트러블슈팅

```bash
# SNR Operator 로그 확인
oc logs -n openshift-workload-availability \
  deployment/self-node-remediation-operator-controller-manager

# SNR DaemonSet Pod 로그 확인
oc logs -n openshift-workload-availability \
  -l app.kubernetes.io/name=self-node-remediation \
  --prefix

# SNR 이벤트 확인
oc get events -n openshift-workload-availability --sort-by='.lastTimestamp'
```
