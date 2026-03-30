# NetworkPolicy / MultiNetworkPolicy 실습

두 개의 네임스페이스에 VM을 배포하고 네트워크 정책으로 트래픽을 제어합니다.
`04-network-policy.sh` 실행 시 두 가지 방식 중 하나를 선택합니다.

---

## 방식 비교

| 항목 | NetworkPolicy | MultiNetworkPolicy |
|------|--------------|-------------------|
| API | `networking.k8s.io/v1` | `k8s.cni.cncf.io/v1beta1` |
| 적용 대상 | pod network (eth0, masquerade) | secondary NIC (eth1) |
| 네트워크 | Linux Bridge (02-network 방식 1/3) | OVN Localnet (02-network 방식 2/4) |
| 네임스페이스 | `poc-network-policy-1/2` | `poc-multi-network-policy-1/2` |
| NAD | `poc-bridge-nad` | `poc-localnet-nad` |
| 사전 요건 | NNCP Linux Bridge | NNCP OVN Localnet + `useMultiNetworkPolicy: true` |

> **핵심 차이**: NetworkPolicy는 pod network(eth0)에만 적용됩니다.
> Linux Bridge secondary NIC(eth1)을 통한 트래픽은 NetworkPolicy 대상 외입니다.
> MultiNetworkPolicy는 secondary NIC(eth1)을 직접 제어합니다.

---

## 방식 1. NetworkPolicy (Linux Bridge)

```
poc-network-policy-1                      poc-network-policy-2
┌────────────────────┐            ┌────────────────────┐
│  poc-vm-1          │            │  poc-vm-2          │
│  eth0 ──────────── │──✗ 기본────│ ──────── eth0      │
│  (NetworkPolicy    │            │    NetworkPolicy)   │
│  eth1: br1 bypass) │            │  (eth1: br1 bypass) │
└────────────────────┘            └────────────────────┘
         │   allow-from-ns1-vm-ip 적용 후 (eth0 기준)   ▲
         └─────────────────────────────────────────────┘
```

### 사전 조건

- 02-network 방식 1(Linux Bridge) 또는 3(Linux Bridge + VLAN) 완료

### 적용되는 정책

```yaml
# Default Deny All
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: poc-network-policy-1
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
```

```yaml
# Allow Same Namespace
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-same-namespace
  namespace: poc-network-policy-1
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - podSelector: {}
  egress:
    - to:
        - podSelector: {}
```

### 정책 확인

```bash
oc get networkpolicy -n poc-network-policy-1
oc get networkpolicy -n poc-network-policy-2
```

---

## 방식 2. MultiNetworkPolicy (OVN Localnet)

```
poc-multi-network-policy-1                poc-multi-network-policy-2
┌────────────────────┐            ┌────────────────────┐
│  poc-vm-1          │            │  poc-vm-2          │
│  eth0 (pod net)    │            │  eth0 (pod net)    │
│  eth1 ─────────── │──✗ 기본────│ ─────────── eth1   │
│  (MultiNetPolicy   │            │   MultiNetPolicy)  │
│   OVN Localnet)    │            │   OVN Localnet)    │
└────────────────────┘            └────────────────────┘
         │   allow-from-ns1-vm-ip 적용 후 (eth1 기준)    ▲
         └─────────────────────────────────────────────┘
```

### 사전 조건

- 02-network 방식 2(OVN Localnet) 또는 4(OVN Localnet + VLAN) 완료
- `useMultiNetworkPolicy: true` 활성화 (스크립트가 자동 처리)

### MultiNetworkPolicy 활성화

```bash
# 스크립트가 자동 실행하지만, 수동으로 활성화하려면:
oc patch network.operator.openshift.io cluster --type=merge \
  -p '{"spec":{"useMultiNetworkPolicy":true}}'

# 활성화 확인
oc get network.operator.openshift.io cluster \
  -o jsonpath='{.spec.useMultiNetworkPolicy}'
```

### 적용되는 정책

MultiNetworkPolicy는 `k8s.v1.cni.cncf.io/policy-for` annotation으로 어떤 NAD(secondary NIC)에 적용할지 지정합니다.

```yaml
# Default Deny All (eth1 기준)
apiVersion: k8s.cni.cncf.io/v1beta1
kind: MultiNetworkPolicy
metadata:
  name: default-deny-all
  namespace: poc-multi-network-policy-1
  annotations:
    k8s.v1.cni.cncf.io/policy-for: poc-multi-network-policy-1/poc-localnet-nad
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
```

```yaml
# Allow Same Namespace (eth1 기준)
apiVersion: k8s.cni.cncf.io/v1beta1
kind: MultiNetworkPolicy
metadata:
  name: allow-same-namespace
  namespace: poc-multi-network-policy-1
  annotations:
    k8s.v1.cni.cncf.io/policy-for: poc-multi-network-policy-1/poc-localnet-nad
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - podSelector: {}
  egress:
    - to:
        - podSelector: {}
```

### 정책 확인

```bash
oc get multinetworkpolicy -n poc-multi-network-policy-1
oc get multinetworkpolicy -n poc-multi-network-policy-2
```

---

## VM IP 할당 (cloud-init networkData)

`04-network-policy.sh`가 VM 생성 시 cloud-init으로 eth1 정적 IP를 자동 설정합니다.

| VM | 네임스페이스 | eth1 IP |
|----|-------------|---------|
| poc-vm-1 (NS1) | poc-network-policy-1 / poc-multi-network-policy-1 | `SECONDARY_IP_PREFIX`.11/24 |
| poc-vm-2 (NS2) | poc-network-policy-2 / poc-multi-network-policy-2 | `SECONDARY_IP_PREFIX`.12/24 |

> `SECONDARY_IP_PREFIX` 기본값: `192.168.100` (env.conf에서 변경 가능)

```yaml
# cloud-init networkData 형식 (version 2)
version: 2
ethernets:
  eth1:
    dhcp4: false
    addresses:
      - 192.168.100.11/24       # NS1 VM
    gateway4: 192.168.100.1
    nameservers:
      addresses:
        - 8.8.8.8
```

## VM 상태 및 IP 확인

```bash
# 방식 1 (NetworkPolicy) — pod network IP 사용
NS1="poc-network-policy-1"
NS2="poc-network-policy-2"

# 방식 2 (MultiNetworkPolicy) — secondary NIC IP 사용
NS1="poc-multi-network-policy-1"
NS2="poc-multi-network-policy-2"

# VM 실행 상태
oc get vmi -n $NS1
oc get vmi -n $NS2

# 방식 1: pod network IP (eth0)
oc get vmi -n $NS1 \
  -o jsonpath='{.items[0].status.interfaces[0].ipAddress}'

# 방식 2: secondary NIC IP (eth1, OVN Localnet)
oc get vmi -n $NS1 \
  -o jsonpath='{.items[0].status.interfaces[?(@.name=="secondary")].ipAddress}'
```

---

## NS1 → NS2 특정 IP 허용

### 방식 1 — netpol-allow-from-ns1-ip.yaml 수정 후 적용

```bash
# NS1 VM IP 확인 (eth0)
NS1_VM_IP=$(oc get vmi -n poc-network-policy-1 \
  -o jsonpath='{.items[0].status.interfaces[0].ipAddress}')
echo "NS1 VM IP: ${NS1_VM_IP}"

# netpol-allow-from-ns1-ip.yaml 에서 192.168.0.1/32 → 실제 IP/32 로 교체 후 적용
sed -i "s|192.168.0.1/32|${NS1_VM_IP}/32|" netpol-allow-from-ns1-ip.yaml
oc apply -f netpol-allow-from-ns1-ip.yaml
```

### 방식 2 — multi-netpol-allow-from-ns1-ip.yaml 수정 후 적용

```bash
# NS1 VM secondary NIC IP 확인 (eth1)
NS1_VM_IP=$(oc get vmi -n poc-multi-network-policy-1 \
  -o jsonpath='{.items[0].status.interfaces[?(@.name=="secondary")].ipAddress}')
echo "NS1 VM secondary IP: ${NS1_VM_IP}"

# multi-netpol-allow-from-ns1-ip.yaml 에서 IP 교체 후 적용
sed -i "s|192.168.0.1/32|${NS1_VM_IP}/32|" multi-netpol-allow-from-ns1-ip.yaml
oc apply -f multi-netpol-allow-from-ns1-ip.yaml
```

---

## 통신 테스트

```bash
# NS1 VM 콘솔 접속 (방식에 따라 네임스페이스 변경)
virtctl console poc-vm-1 -n poc-network-policy-1
# 또는
virtctl console poc-vm-1 -n poc-multi-network-policy-1

# VM 내부에서 NS2 VM으로 ping 테스트
# allow-from-ns1-vm-ip 적용 전 → 실패
# allow-from-ns1-vm-ip 적용 후 → 성공
ping -c 3 <NS2_VM_IP>
curl -v http://<NS2_VM_IP>
```

---

## 트러블슈팅

### MultiNetworkPolicy가 동작하지 않는 경우

```bash
# useMultiNetworkPolicy 활성화 확인
oc get network.operator.openshift.io cluster \
  -o jsonpath='{.spec.useMultiNetworkPolicy}'

# 네트워크 오퍼레이터 상태 확인
oc get network.operator.openshift.io cluster \
  -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}'

# MultiNetworkPolicy 컨트롤러 Pod 확인
oc get pods -n openshift-multus | grep multi-networkpolicy

# 정책 annotation 확인 (NAD 이름 불일치 확인)
oc get multinetworkpolicy -n poc-multi-network-policy-1 -o yaml \
  | grep "policy-for"
```

### NetworkPolicy가 secondary NIC에 적용되지 않는 경우

NetworkPolicy는 pod network(eth0)에만 적용됩니다.
Linux Bridge secondary NIC(eth1)을 통한 트래픽을 제어하려면 MultiNetworkPolicy(방식 2)를 사용하세요.

---

## 롤백

```bash
# 방식 1
oc delete networkpolicy --all -n poc-network-policy-1
oc delete networkpolicy --all -n poc-network-policy-2
oc delete vm --all -n poc-network-policy-1
oc delete vm --all -n poc-network-policy-2
oc delete namespace poc-network-policy-1 poc-network-policy-2

# 방식 2
oc delete multinetworkpolicy --all -n poc-multi-network-policy-1
oc delete multinetworkpolicy --all -n poc-multi-network-policy-2
oc delete vm --all -n poc-multi-network-policy-1
oc delete vm --all -n poc-multi-network-policy-2
oc delete namespace poc-multi-network-policy-1 poc-multi-network-policy-2
```
