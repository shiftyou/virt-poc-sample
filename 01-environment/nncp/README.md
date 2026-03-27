# NNCP (NodeNetworkConfigurationPolicy) 구성

## 개요

NNCP(NodeNetworkConfigurationPolicy)는 노드의 네트워크 인터페이스를 선언적으로 구성합니다.
OpenShift Virtualization에서 VM이 물리 네트워크에 직접 연결되도록 Linux Bridge를 생성할 때 사용합니다.

NMState Operator가 NNCP를 감시하고 각 노드에 네트워크 설정을 적용합니다.

---

## 사전 조건

- NMState Operator 설치 (OpenShift Virtualization 설치 시 자동 포함)
- 노드의 네트워크 인터페이스 이름 확인 (`setup.sh`에서 `BRIDGE_INTERFACE` 입력)

### 노드 인터페이스 이름 확인

```bash
# 노드 목록 확인
oc get nodes

# 특정 노드의 네트워크 인터페이스 확인
oc debug node/<node-name> -- ip link show

# 또는 NodeNetworkState로 확인
oc get nodenetworkstate <node-name> -o yaml | grep -A5 "interfaces:"
```

---

## 적용 방법

```bash
# 프로젝트 루트에서
source env.conf

cd 01-environment/nncp

# NNCP 적용
envsubst < nncp-bridge.yaml | oc apply -f -

# 또는 apply.sh 사용
./apply.sh
```

---

## 파일 설명

| 파일 | 설명 |
|------|------|
| `nncp-bridge.yaml` | Linux Bridge 생성 NNCP |
| `consoleYamlSample.yaml` | Console에서 직접 적용 가능한 샘플 |
| `apply.sh` | envsubst 변수 치환 후 적용 |

---

## 상태 확인

```bash
# NNCP 적용 상태 확인 (Available이 True여야 함)
oc get nncp

# 특정 NNCP 상세 확인
oc describe nncp poc-bridge-nncp

# 각 노드의 네트워크 상태 확인
oc get nodenetworkstate

# 특정 노드의 네트워크 설정 확인
oc get nodenetworkstate <node-name> -o yaml

# Bridge 인터페이스 확인 (노드에서)
oc debug node/<node-name> -- ip link show ${BRIDGE_NAME}
oc debug node/<node-name> -- bridge link show
```

---

## 네트워크 상태 확인 (CPU/Memory/Network)

```bash
# 노드별 네트워크 인터페이스 목록
oc get nodenetworkstate -o custom-columns="NODE:.metadata.name"

# 네트워크 설정 동기화 상태 확인
oc get nncp -o custom-columns="NAME:.metadata.name,STATUS:.status.conditions[0].type,REASON:.status.conditions[0].reason"

# NMState Pod 상태 확인
oc get pods -n openshift-nmstate

# NMState 로그 확인
oc logs -n openshift-nmstate -l component=kubernetes-nmstate-handler
```

---

## NNCP 롤백

```bash
# NNCP 삭제 (브리지 설정 제거)
oc delete nncp poc-bridge-nncp

# 특정 노드에서 브리지 수동 제거
oc debug node/<node-name> -- nmcli connection delete ${BRIDGE_NAME}
```

---

## 트러블슈팅

```bash
# NNCP 적용 실패 시 이벤트 확인
oc describe nncp poc-bridge-nncp

# NodeNetworkConfigurationEnactment 확인 (노드별 적용 상태)
oc get nnce

# 특정 노드의 enactment 상세 확인
oc describe nnce <node-name>.poc-bridge-nncp

# NMState handler 로그 확인
oc logs -n openshift-nmstate -l component=kubernetes-nmstate-handler -f

# 노드에서 직접 네트워크 상태 확인
oc debug node/<node-name> -- nmstatectl show
```
