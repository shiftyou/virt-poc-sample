# 네트워크 구성 (NNCP / NAD)

OpenShift Virtualization에서 VM이 물리 네트워크에 연결되도록
NNCP(NodeNetworkConfigurationPolicy)와 NAD(NetworkAttachmentDefinition)를 구성합니다.

`02-network.sh` 실행 시 4가지 방식 중 하나를 선택합니다.

---

## 방식 비교

| 항목 | Linux Bridge | OVN Localnet | Linux Bridge + VLAN | OVN Localnet + VLAN |
|------|-------------|-------------|---------------------|---------------------|
| CNI 드라이버 | `cnv-bridge` | `ovn-k8s-cni-overlay` | `cnv-bridge` | `ovn-k8s-cni-overlay` |
| VLAN 분리 | ❌ | ❌ | ✅ (NAD에 VLAN ID 지정) | ✅ (NAD에 vlanID 지정) |
| OVN 포트 보안·ACL | ❌ | ✅ | ❌ | ✅ |
| 스위치 요구 사항 | Access 또는 Trunk | Trunk (OVN이 처리) | Trunk | Trunk |
| NNCP 추가 설정 | bridge only | bridge + `ovn.bridge-mappings` | bridge + VLAN trunk port | bridge + `ovn.bridge-mappings` |

---

## 사전 조건

- NMState Operator 설치 및 NMState CR 생성 (`00-operator/nmstate-operator.md` 참조)
- `env.conf`에 `BRIDGE_INTERFACE`, `BRIDGE_NAME`, `SECONDARY_IP_PREFIX` 설정
- 네임스페이스 : `poc-network` (고정)

```bash
# NMState Operator 상태
oc get csv -n openshift-nmstate | grep nmstate

# NMState CR 존재 여부
oc get nmstate

# 노드 인터페이스 이름 확인
oc get nns <worker-node> \
  -o jsonpath='{range .status.currentState.interfaces[?(@.type=="ethernet")]}{.name}{"\n"}{end}'
```

---

## 방식 1. Linux Bridge

```
물리 NIC (BRIDGE_INTERFACE)
    │  NNCP → Linux Bridge 생성
    ▼
Linux Bridge (BRIDGE_NAME)
    │  NAD → cnv-bridge CNI
    ▼
VM eth1 (L2 직접 연결)
```

### NNCP

```yaml
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: poc-bridge-nncp
spec:
  nodeSelector:
    node-role.kubernetes.io/worker: ""
  desiredState:
    interfaces:
      - name: br1                     # BRIDGE_NAME
        type: linux-bridge
        state: up
        ipv4:
          enabled: false
        bridge:
          options:
            stp:
              enabled: false
          port:
            - name: ens4              # BRIDGE_INTERFACE
```

### NAD

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: poc-bridge-nad
  namespace: poc-network
  annotations:
    k8s.v1.cni.cncf.io/resourceName: bridge.network.kubevirt.io/br1
spec:
  config: '{
    "cniVersion": "0.3.1",
    "name": "poc-bridge-nad",
    "type": "cnv-bridge",
    "bridge": "br1",
    "macspoofchk": true,
    "ipam": {}
  }'
```

---

## 방식 2. OVN Localnet

OVN-Kubernetes가 스위칭을 처리합니다.
NNCP에 `ovn.bridge-mappings`를 추가하여 물리 브리지를 OVN localnet 이름에 매핑합니다.

> **핵심**: NNCP의 `bridge-mappings[].localnet` 값과 NAD CNI config의 `"name"` 값이 **일치**해야 합니다.

```
물리 NIC (BRIDGE_INTERFACE)
    │  NNCP → Linux Bridge + OVN bridge-mappings
    ▼
Linux Bridge (BRIDGE_NAME) ← OVN localnet: "poc-localnet"
    │  NAD → ovn-k8s-cni-overlay CNI
    ▼
VM eth1 (OVN 포트 보안·ACL 적용)
```

### NNCP

```yaml
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: poc-localnet-nncp
spec:
  nodeSelector:
    node-role.kubernetes.io/worker: ""
  desiredState:
    interfaces:
      - name: br1
        type: linux-bridge
        state: up
        ipv4:
          enabled: false
        bridge:
          options:
            stp:
              enabled: false
          port:
            - name: ens4
    ovn:
      bridge-mappings:
        - localnet: poc-localnet      # NAD의 "name" 값과 일치해야 함
          bridge: br1
          state: present
```

### NAD

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: poc-localnet-nad
  namespace: poc-network
spec:
  config: '{
    "cniVersion": "0.3.1",
    "name": "poc-localnet",           # NNCP bridge-mappings localnet 값과 일치
    "type": "ovn-k8s-cni-overlay",
    "topology": "localnet",
    "netAttachDefName": "poc-network/poc-localnet-nad"
  }'
```

---

## 방식 3. Linux Bridge + VLAN filtering

Linux Bridge 포트를 **trunk 모드**로 구성하여 단일 물리 NIC으로 여러 VLAN을 분리합니다.
NAD마다 다른 VLAN ID를 지정하여 VM을 원하는 VLAN에 배치할 수 있습니다.

> 물리 스위치 포트도 **trunk 모드**로 설정되어 있어야 합니다.

```
물리 NIC (BRIDGE_INTERFACE) — 스위치 trunk 포트에 연결
    │  NNCP → Linux Bridge + VLAN trunk port
    ▼
Linux Bridge (BRIDGE_NAME)
    │  NAD → cnv-bridge + vlan: 100
    ▼
VM eth1 (VLAN 100에 배치됨)
```

### NNCP

```yaml
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: poc-bridge-nncp
spec:
  nodeSelector:
    node-role.kubernetes.io/worker: ""
  desiredState:
    interfaces:
      - name: br1
        type: linux-bridge
        state: up
        ipv4:
          enabled: false
        bridge:
          options:
            stp:
              enabled: false
          port:
            - name: ens4
              vlan:
                mode: trunk            # VLAN 필터링 활성화
                trunk-tags:
                  - id-range:
                      min: 1
                      max: 4094        # 전체 VLAN 허용 (필요 시 범위 축소)
```

### NAD (VLAN 100 예시)

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: poc-bridge-vlan-nad
  namespace: poc-network
  annotations:
    k8s.v1.cni.cncf.io/resourceName: bridge.network.kubevirt.io/br1
spec:
  config: '{
    "cniVersion": "0.3.1",
    "name": "poc-bridge-vlan-nad",
    "type": "cnv-bridge",
    "bridge": "br1",
    "vlan": 100,                       # VM이 연결될 VLAN ID
    "macspoofchk": true,
    "ipam": {}
  }'
```

> 다른 VLAN(예: 200)이 필요하면 동일 NNCP를 재사용하고 NAD만 새로 만들어 `"vlan": 200`으로 설정합니다.

---

## 방식 4. OVN Localnet + VLAN

OVN bridge-mappings + NAD에 `vlanID`를 지정합니다.
NNCP는 방식 2와 동일하며, NAD에만 `vlanID`를 추가합니다.

```
물리 NIC (BRIDGE_INTERFACE) — 스위치 trunk 포트에 연결
    │  NNCP → Linux Bridge + OVN bridge-mappings
    ▼
Linux Bridge ← OVN localnet: "poc-localnet"
    │  NAD → ovn-k8s-cni-overlay + vlanID: 100
    ▼
VM eth1 (OVN 포트 보안 + VLAN 100)
```

### NNCP

방식 2의 NNCP와 동일합니다 (`poc-localnet-nncp`).

### NAD (VLAN 100 예시)

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: poc-localnet-vlan-nad
  namespace: poc-network
spec:
  config: '{
    "cniVersion": "0.3.1",
    "name": "poc-localnet",
    "type": "ovn-k8s-cni-overlay",
    "topology": "localnet",
    "netAttachDefName": "poc-network/poc-localnet-vlan-nad",
    "vlanID": 100
  }'
```

---

## VM 생성 (공통)

선택된 NAD를 보조 네트워크로 연결하고, cloud-init으로 eth1 정적 IP를 설정합니다.
VM은 2대(`poc-network-vm-1`, `poc-network-vm-2`) 배포됩니다.

| VM | eth1 IP |
|----|---------|
| poc-network-vm-1 | `SECONDARY_IP_PREFIX`.10/24 |
| poc-network-vm-2 | `SECONDARY_IP_PREFIX`.11/24 |

> `SECONDARY_IP_PREFIX` 기본값: `192.168.100` (env.conf에서 변경 가능)
> `02-network.sh`가 아래 패치를 자동으로 수행합니다.

```bash
NAD_NAME="poc-bridge-nad"           # 선택한 방식에 따라 변경
SECONDARY_IP_PREFIX="192.168.100"   # env.conf 값 사용

for suffix in 1 2; do
  VM_NAME="poc-network-vm-${suffix}"
  IP_SUFFIX=$([ "$suffix" = "1" ] && echo "10" || echo "11")

  # poc 템플릿으로 VM 생성 (Halted 상태)
  oc process -n openshift poc -p NAME="${VM_NAME}" \
    | sed 's/  running: false/  runStrategy: Halted/' \
    | oc apply -n "poc-network" -f -

  # 보조 NIC 추가
  oc patch vm "${VM_NAME}" -n "poc-network" --type=json -p='[
    {
      "op": "add",
      "path": "/spec/template/spec/domain/devices/interfaces/-",
      "value": {"name": "bridge-net", "bridge": {}, "model": "virtio"}
    },
    {
      "op": "add",
      "path": "/spec/template/spec/networks/-",
      "value": {"name": "bridge-net", "multus": {"networkName": "'"${NAD_NAME}"'"}}
    }
  ]'

  # 기존 cloudinitdisk 볼륨에 networkData 추가 (VM 시작 전)
  CI_IDX=$(oc get vm "${VM_NAME}" -n "poc-network" -o json | \
    python3 -c "
import json, sys
vols = json.load(sys.stdin)['spec']['template']['spec']['volumes']
print(next(i for i, v in enumerate(vols) if 'cloudInitNoCloud' in v))
")
  oc patch vm "${VM_NAME}" -n "poc-network" --type=json -p="[
    {\"op\": \"add\",
     \"path\": \"/spec/template/spec/volumes/${CI_IDX}/cloudInitNoCloud/networkData\",
     \"value\": \"version: 2\nethernets:\n  eth1:\n    dhcp4: false\n    addresses:\n      - ${SECONDARY_IP_PREFIX}.${IP_SUFFIX}/24\n    gateway4: ${SECONDARY_IP_PREFIX}.1\n    nameservers:\n      addresses:\n        - 8.8.8.8\n\"}
  ]"

  virtctl start "${VM_NAME}" -n "poc-network"
done
```

결과적으로 `cloudinitdisk` 볼륨:

```yaml
- name: cloudinitdisk
  cloudInitNoCloud:
    userData: |-
      #cloud-config
      user: cloud-user
      password: ...
      chpasswd: { expire: False }
    networkData: |
      version: 2
      ethernets:
        eth1:
          dhcp4: false
          addresses:
            - 192.168.100.10/24
          gateway4: 192.168.100.1
          nameservers:
            addresses:
              - 8.8.8.8
```

### VM 네트워크 확인

```bash
# VMI NIC 상태 (두 VM 모두)
for vm in poc-network-vm-1 poc-network-vm-2; do
  echo "=== ${vm} ==="
  oc get vmi "${vm}" -n "poc-network" \
    -o jsonpath='{range .status.interfaces[*]}{.name}: {.ipAddress}{"\n"}{end}'
done

# VM 콘솔 접속
virtctl console poc-network-vm-1 -n "poc-network"
# ip addr show eth1
# ping 192.168.100.11   ← vm-2로 통신 테스트
```

---

## 상태 확인

```bash
# NNCP 상태
oc get nncp

# 노드별 적용 상태 (NNCE)
oc get nnce

# NodeNetworkState에서 브리지 확인
oc get nns <node> -o yaml | grep -A5 "linux-bridge"

# OVN bridge-mappings 확인 (방식 2/4)
oc get nncp poc-localnet-nncp -o jsonpath='{.spec.desiredState.ovn}' | python3 -m json.tool

# NAD 목록
oc get net-attach-def -n poc-network
```

---

## 롤백

```bash
# NAD 삭제
oc delete net-attach-def -n poc-network --all

# NNCP 삭제 (Bridge 제거)
oc delete nncp poc-bridge-nncp poc-localnet-nncp 2>/dev/null || true

# 네임스페이스 삭제
oc delete namespace poc-network
```

---

## 트러블슈팅

```bash
# NNCP 실패 원인 확인
oc describe nncp <nncp-name>

# 노드별 NNCE 오류 확인
oc describe nnce <node>.<nncp-name>

# NMState 핸들러 로그
oc logs -n openshift-nmstate -l component=kubernetes-nmstate-handler -f

# 노드에서 직접 네트워크 상태 확인
oc debug node/<node> -- chroot /host nmstatectl show

# OVN localnet 매핑 확인 (방식 2/4)
oc debug node/<node> -- chroot /host ovs-vsctl list open .
```

### OVN Localnet — localnet 이름 불일치

NNCP `bridge-mappings[].localnet` 값과 NAD CNI config `"name"` 값이 다르면
VM 네트워크 인터페이스가 생성되지 않습니다.

```bash
# NNCP의 localnet 이름 확인
oc get nncp poc-localnet-nncp \
  -o jsonpath='{.spec.desiredState.ovn.bridge-mappings[0].localnet}'

# NAD CNI config의 name 확인
oc get net-attach-def poc-localnet-nad -n poc-network \
  -o jsonpath='{.spec.config}' | python3 -m json.tool | grep '"name"'
```

두 값이 동일해야 합니다.
