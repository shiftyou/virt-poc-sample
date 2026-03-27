# Network Policy — VM 간 트래픽 제어 실습

## 개요

두 개의 네임스페이스(`poc-network-policy1`, `poc-network-policy2`)에 각각 VM을 배치하고,
NetworkPolicy로 트래픽을 제어합니다.

**시나리오 목표:**
1. 기본 상태: Deny-All + Allow-Same-Namespace → 다른 네임스페이스 VM 간 ping 불가
2. `network-policy1-vm`의 IP를 `poc-network-policy2`에서 허용 → 단방향 ping 가능
   - policy1-vm → policy2-vm: **ping 가능** ✔
   - policy2-vm → policy1-vm: **ping 불가** ✘

---

## 파일 설명

| 파일 | 설명 |
|------|------|
| [`namespace.yaml`](namespace.yaml) | poc-network-policy1, poc-network-policy2 네임스페이스 |
| [`vm-ns1.yaml`](vm-ns1.yaml) | network-policy1-vm (poc-network-policy1) |
| [`vm-ns2.yaml`](vm-ns2.yaml) | network-policy2-vm (poc-network-policy2) |
| [`networkpolicy-deny-all.yaml`](networkpolicy-deny-all.yaml) | 두 네임스페이스에 Deny-All 정책 |
| [`networkpolicy-allow-same-ns.yaml`](networkpolicy-allow-same-ns.yaml) | 동일 네임스페이스 내 통신 허용 |
| [`networkpolicy-allow-from-ns1.yaml`](networkpolicy-allow-from-ns1.yaml) | ns1 VM IP → ns2 단방향 허용 |
| [`apply.sh`](apply.sh) | 기본 정책 일괄 적용 스크립트 |

---

## 사전 조건

- `rhel9-poc-golden` DataSource가 `openshift-virtualization-os-images`에 등록되어 있어야 합니다.
  (`00-init/pvc-to-qcow2.md` Part 2 참조)

---

## Step 1: 네임스페이스 및 기본 정책 적용

```bash
# 네임스페이스 생성
oc apply -f namespace.yaml

# Deny-All 정책 적용 (두 네임스페이스)
oc apply -f networkpolicy-deny-all.yaml

# 동일 네임스페이스 내 통신 허용 (두 네임스페이스)
oc apply -f networkpolicy-allow-same-ns.yaml

# 현재 적용된 정책 확인
oc get networkpolicy -n poc-network-policy1
oc get networkpolicy -n poc-network-policy2
```

---

## Step 2: VM 생성 및 시작

```bash
# VM 생성
oc apply -f vm-ns1.yaml
oc apply -f vm-ns2.yaml

# VM 시작
virtctl start network-policy1-vm -n poc-network-policy1
virtctl start network-policy2-vm -n poc-network-policy2

# VM Running 상태 대기
oc wait vmi/network-policy1-vm -n poc-network-policy1 \
  --for=condition=Ready --timeout=300s
oc wait vmi/network-policy2-vm -n poc-network-policy2 \
  --for=condition=Ready --timeout=300s

# VM IP 확인
oc get vmi -n poc-network-policy1
oc get vmi -n poc-network-policy2
```

---

## Step 3: 크로스 네임스페이스 ping 차단 확인

```bash
# network-policy2-vm IP 확인
NS2_VM_IP=$(oc get vmi network-policy2-vm -n poc-network-policy2 \
  -o jsonpath='{.status.interfaces[0].ipAddress}')
echo "network-policy2-vm IP: $NS2_VM_IP"

# network-policy1-vm 콘솔에서 network-policy2-vm 으로 ping 시도 (실패해야 함)
virtctl ssh cloud-user@network-policy1-vm -n poc-network-policy1
# (VM 내부에서)
ping -c 3 $NS2_VM_IP    # ← timeout, 실패 확인
```

---

## Step 4: network-policy1-vm IP 기반 단방향 허용 적용

```bash
# network-policy1-vm IP 확인
NS1_VM_IP=$(oc get vmi network-policy1-vm -n poc-network-policy1 \
  -o jsonpath='{.status.interfaces[0].ipAddress}')
echo "network-policy1-vm IP: $NS1_VM_IP"

# poc-network-policy2 에서 ns1 VM IP 허용 정책 적용
NETWORK_POLICY1_VM_IP=${NS1_VM_IP} \
  envsubst < networkpolicy-allow-from-ns1.yaml | oc apply -f -

# 적용 확인
oc get networkpolicy -n poc-network-policy2
oc describe networkpolicy allow-from-ns1-vm -n poc-network-policy2
```

---

## Step 5: 단방향 ping 동작 확인

```bash
# [policy1-vm → policy2-vm] 성공해야 함 ✔
virtctl ssh cloud-user@network-policy1-vm -n poc-network-policy1
# (VM 내부에서)
ping -c 3 ${NS2_VM_IP}    # ← 성공

# [policy2-vm → policy1-vm] 실패해야 함 ✘
NS1_VM_IP=$(oc get vmi network-policy1-vm -n poc-network-policy1 \
  -o jsonpath='{.status.interfaces[0].ipAddress}')

virtctl ssh cloud-user@network-policy2-vm -n poc-network-policy2
# (VM 내부에서)
ping -c 3 ${NS1_VM_IP}    # ← timeout, 실패
```

---

## 정리

```bash
# VM 삭제
oc delete vm network-policy1-vm -n poc-network-policy1
oc delete vm network-policy2-vm -n poc-network-policy2

# PVC 삭제
oc delete pvc -n poc-network-policy1 --all
oc delete pvc -n poc-network-policy2 --all

# 네임스페이스 삭제
oc delete namespace poc-network-policy1 poc-network-policy2
```

---

## 트러블슈팅

```bash
# NetworkPolicy 상세 확인
oc describe networkpolicy -n poc-network-policy1
oc describe networkpolicy -n poc-network-policy2

# VMI 상태 및 IP 확인
oc get vmi -A -o wide

# OVN-K 흐름 규칙 확인
oc exec -n openshift-ovn-kubernetes \
  $(oc get pod -n openshift-ovn-kubernetes -l app=ovnkube-node -o name | head -1) \
  -- ovs-ofctl dump-flows br-int 2>/dev/null | grep -i "nw_dst=<vm-ip>"
```
