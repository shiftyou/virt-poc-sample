# 네트워크 구성 (NNCP / NAD)

OpenShift Virtualization에서 VM이 물리 네트워크에 직접 연결되도록
Linux Bridge를 생성하고 NetworkAttachmentDefinition을 등록합니다.

```
물리 네트워크 (예: VLAN, 외부망)
        │
  노드 NIC (BRIDGE_INTERFACE, 예: ens4)
        │  NNCP 적용 → Linux Bridge 생성
        ▼
  Linux Bridge (BRIDGE_NAME, 예: br1)
        │  NAD 등록
        ▼
  NetworkAttachmentDefinition (poc-bridge-nad)
        │  VM에서 보조 네트워크로 선택
        ▼
  VM eth1 (물리 네트워크 직접 연결)
```

---

## 사전 조건

- NMState Operator 설치 및 NMState CR 생성 (`00-operator/08-nmstate-operator.md` 참조)
- `env.conf`에 `BRIDGE_INTERFACE`, `BRIDGE_NAME`, `NAD_NAMESPACE` 설정

### 사전 조건 확인

```bash
# NMState Operator 상태
oc get csv -n openshift-nmstate | grep nmstate

# NMState CR 존재 여부
oc get nmstate

# 노드 인터페이스 이름 확인 (NMState 설치된 경우)
oc get nns <worker-node> \
  -o jsonpath='{range .status.currentState.interfaces[?(@.type=="ethernet")]}{.name}{"\n"}{end}'

# NMState 미설치 시 대안
oc debug node/<worker-node> -- chroot /host ip link show
```

---

## 구성 순서

### 1단계: NNCP — Linux Bridge 생성

모든 워커 노드에 Linux Bridge(`BRIDGE_NAME`)를 생성하고
물리 인터페이스(`BRIDGE_INTERFACE`)를 Bridge 포트로 연결합니다.

```bash
source env.conf

# env.conf 변수 확인
echo "Interface : $BRIDGE_INTERFACE"
echo "Bridge    : $BRIDGE_NAME"

# NNCP 적용
oc apply -f - <<EOF
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: poc-bridge-nncp
spec:
  nodeSelector:
    node-role.kubernetes.io/worker: ""
  desiredState:
    interfaces:
      - name: ${BRIDGE_NAME}
        description: "POC VM용 Linux Bridge (${BRIDGE_INTERFACE} 기반)"
        type: linux-bridge
        state: up
        ipv4:
          enabled: false
        ipv6:
          enabled: false
        bridge:
          options:
            stp:
              enabled: false
          port:
            - name: ${BRIDGE_INTERFACE}
EOF
```

#### NNCP 적용 확인

```bash
# 전체 NNCP 상태 (Available=True 확인)
oc get nncp

# 노드별 적용 상태 확인 (NNCE: NodeNetworkConfigurationEnactment)
oc get nnce

# 특정 노드의 적용 상태 상세
oc describe nnce <node-name>.poc-bridge-nncp

# 노드에서 Bridge 생성 확인
oc debug node/<worker-node> -- ip link show ${BRIDGE_NAME}
```

> NNCP 상태가 `Available: False`이면 `oc describe nncp poc-bridge-nncp`로 원인 확인

---

### 2단계: NAD — NetworkAttachmentDefinition 등록

NNCP로 생성된 Linux Bridge를 VM 네트워크로 사용할 수 있도록
NetworkAttachmentDefinition을 등록합니다.

```bash
source env.conf

# 네임스페이스 생성
oc new-project ${NAD_NAMESPACE} 2>/dev/null || true

# NAD 등록
oc apply -f - <<EOF
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: poc-bridge-nad
  namespace: ${NAD_NAMESPACE}
  annotations:
    k8s.v1.cni.cncf.io/resourceName: bridge.network.kubevirt.io/${BRIDGE_NAME}
spec:
  config: '{
    "cniVersion": "0.3.1",
    "name": "poc-bridge-nad",
    "type": "cnv-bridge",
    "bridge": "${BRIDGE_NAME}",
    "macspoofchk": true,
    "ipam": {}
  }'
EOF
```

#### NAD 확인

```bash
# NAD 등록 확인
oc get net-attach-def -n ${NAD_NAMESPACE}

# 상세 확인
oc describe net-attach-def poc-bridge-nad -n ${NAD_NAMESPACE}
```

---

## 자동 적용

`02-network.sh`를 실행하면 NNCP → NAD → VM 생성을 순서대로 적용하고 상태를 확인합니다.

```bash
./02-network/02-network.sh
```

---

## 3단계: VM 생성 (poc 템플릿 + NAD 보조 네트워크)

`poc` 템플릿으로 VM을 생성하고 `poc-bridge-nad`를 보조 네트워크로 연결합니다.

```
eth0 (masquerade) ── Pod Network
eth1 (bridge)     ── poc-bridge-nad → Linux Bridge → 물리 네트워크
```

```bash
source env.conf

VM_NAME="poc-network-vm"

# poc 템플릿으로 VM 생성
oc process -n openshift poc -p NAME="${VM_NAME}" \
  | oc apply -n "${NAD_NAMESPACE}" -f -

# 보조 NIC (poc-bridge-nad) 추가
oc patch vm "${VM_NAME}" -n "${NAD_NAMESPACE}" --type=json -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/domain/devices/interfaces/-",
    "value": {"name": "bridge-net", "bridge": {}, "model": "virtio"}
  },
  {
    "op": "add",
    "path": "/spec/template/spec/networks/-",
    "value": {"name": "bridge-net", "multus": {"networkName": "poc-bridge-nad"}}
  }
]'

# VM 시작
virtctl start "${VM_NAME}" -n "${NAD_NAMESPACE}"
```

### VM 네트워크 확인

```bash
# VMI NIC 상태 확인
oc get vmi "${VM_NAME}" -n "${NAD_NAMESPACE}" \
  -o jsonpath='{range .status.interfaces[*]}{.name}: {.ipAddress}{"\n"}{end}'

# VM 콘솔에서 직접 확인
virtctl console "${VM_NAME}" -n "${NAD_NAMESPACE}"
# ip addr show
```

> Console에서 VM 생성 시: **Network interfaces** 탭 → **Add network interface** → NAD 이름(`poc-bridge-nad`) 선택

---

## 상태 확인 명령어

```bash
# NNCP 전체 상태
oc get nncp

# 노드별 NNCE 상태
oc get nnce

# NodeNetworkState에서 Bridge 확인
oc get nns <node> -o jsonpath='{range .status.currentState.interfaces[?(@.name=="'${BRIDGE_NAME}'")]}{.name}: {.state}{"\n"}{end}'

# NAD 목록
oc get net-attach-def -A

# NMState Pod 상태
oc get pods -n openshift-nmstate
```

---

## 롤백

```bash
# NAD 삭제
oc delete net-attach-def poc-bridge-nad -n ${NAD_NAMESPACE}

# NNCP 삭제 (Bridge 제거됨)
oc delete nncp poc-bridge-nncp

# 네임스페이스 삭제 (선택)
oc delete namespace ${NAD_NAMESPACE}
```

---

## 트러블슈팅

```bash
# NNCP 실패 시 이벤트 확인
oc describe nncp poc-bridge-nncp

# NNCE로 노드별 실패 원인 확인
oc describe nnce <node>.poc-bridge-nncp

# NMState handler 로그
oc logs -n openshift-nmstate -l component=kubernetes-nmstate-handler -f

# 노드에서 직접 네트워크 상태 확인
oc debug node/<node> -- chroot /host nmstatectl show
```
