# Network Policy (Allow / Deny 예제)

## 개요

NetworkPolicy를 사용하여 Pod 및 VM 간의 네트워크 트래픽을 제어합니다.
기본 Deny-All 정책으로 시작하여 필요한 트래픽만 허용하는 방식을 실습합니다.

---

## 적용 방법

```bash
source ../../env.conf
cd 02-tests/network-policy
./apply.sh
```

---

## 파일 설명

| 파일 | 설명 |
|------|------|
| [`namespace.yaml`](namespace.yaml) | poc-netpol 네임스페이스 |
| [`networkpolicy-deny-all.yaml`](networkpolicy-deny-all.yaml) | 모든 트래픽 차단 (기본 정책) |
| [`networkpolicy-allow-same-ns.yaml`](networkpolicy-allow-same-ns.yaml) | 동일 네임스페이스 내 통신 허용 |
| [`networkpolicy-allow-ingress.yaml`](networkpolicy-allow-ingress.yaml) | 외부 인그레스 트래픽 허용 |

---

## 상태 확인

```bash
# NetworkPolicy 목록 확인
oc get networkpolicy -n poc-netpol

# 특정 NetworkPolicy 상세 확인
oc describe networkpolicy deny-all -n poc-netpol

# Pod 간 통신 테스트
oc run test-client --image=busybox -n poc-netpol --restart=Never -- \
  wget -qO- --timeout=3 http://<target-pod-ip>:80
```

---

## 테스트 방법

```bash
# 1. 테스트 Pod 생성
oc run server --image=nginx --expose --port=80 -n poc-netpol
oc run client --image=busybox -n poc-netpol --restart=Never -- sleep 3600

# 2. Deny-All 정책 적용 전 통신 확인 (성공해야 함)
SERVER_IP=$(oc get pod server -n poc-netpol -o jsonpath='{.status.podIP}')
oc exec client -n poc-netpol -- wget -qO- --timeout=3 http://${SERVER_IP}

# 3. Deny-All 정책 적용
oc apply -f networkpolicy-deny-all.yaml

# 4. Deny-All 적용 후 통신 확인 (실패해야 함 - timeout)
oc exec client -n poc-netpol -- wget -qO- --timeout=3 http://${SERVER_IP}

# 5. Allow 정책 적용
oc apply -f networkpolicy-allow-same-ns.yaml

# 6. Allow 적용 후 통신 확인 (성공해야 함)
oc exec client -n poc-netpol -- wget -qO- --timeout=3 http://${SERVER_IP}
```

---

## 트러블슈팅

```bash
# NetworkPolicy 적용 상태 확인
oc describe networkpolicy -n poc-netpol

# OVN/OVS 규칙 확인
oc exec -n openshift-ovn-kubernetes \
  $(oc get pod -n openshift-ovn-kubernetes -l app=ovnkube-node -o name | head -1) \
  -- ovs-ofctl dump-flows br-int | grep -i "nw_dst=<pod-ip>"

# 네트워크 정책 적용 여부 확인
oc get pod -n poc-netpol -o wide
```
