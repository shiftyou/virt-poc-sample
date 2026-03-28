# NetworkPolicy 실습

두 개의 네임스페이스(`poc-netpol-1`, `poc-netpol-2`)에 VM을 배포하고
NetworkPolicy로 트래픽을 제어하는 실습입니다.

```
poc-netpol-1                    poc-netpol-2
┌──────────────────┐            ┌──────────────────┐
│  poc-vm-1        │            │  poc-vm-2        │
│  (virt-launcher) │            │  (virt-launcher) │
│                  │  ✗ 기본    │                  │
│  default-deny    │──────────▶│  default-deny    │
│  allow-same-ns   │            │  allow-same-ns   │
└──────────────────┘            └──────────────────┘
         │                               ▲
         │  allow-from-ns1-vm-ip 적용 후  │
         └───────────────────────────────┘
```

> **중요**: Kubernetes NetworkPolicy는 Pod 네트워크(마스커레이드, eth0)에 적용됩니다.
> Linux Bridge 보조 NIC(eth1)을 통한 트래픽은 NetworkPolicy 적용 대상이 아닙니다.

---

## 사전 조건

- `01-template` 완료 — poc Template 등록
- `02-network` 완료 — NNCP / Linux Bridge 구성
- `04-network-policy.sh` 실행 완료

---

## 적용된 NetworkPolicy 구조

### Default Deny All (양쪽 네임스페이스)

모든 Ingress / Egress를 차단합니다.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: poc-netpol-1   # poc-netpol-2 동일
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
```

### Allow Same Namespace (양쪽 네임스페이스)

같은 네임스페이스 내 Pod 간 통신을 허용합니다.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-same-namespace
  namespace: poc-netpol-1   # poc-netpol-2 동일
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

---

## NetworkPolicy 확인

```bash
# 정책 목록
oc get networkpolicy -n poc-netpol-1
oc get networkpolicy -n poc-netpol-2

# 상세 확인
oc describe networkpolicy -n poc-netpol-1
oc describe networkpolicy -n poc-netpol-2
```

---

## VM 상태 및 IP 확인

```bash
# VM 실행 상태
oc get vmi -n poc-netpol-1
oc get vmi -n poc-netpol-2

# VM Pod IP 확인 (NetworkPolicy 적용 대상 IP)
oc get vmi -n poc-netpol-1 \
  -o jsonpath='{range .items[*]}{.metadata.name}: {.status.interfaces[0].ipAddress}{"\n"}{end}'

oc get vmi -n poc-netpol-2 \
  -o jsonpath='{range .items[*]}{.metadata.name}: {.status.interfaces[0].ipAddress}{"\n"}{end}'

# 또는 Pod IP 직접 확인
oc get pod -n poc-netpol-1 -l kubevirt.io=virt-launcher \
  -o jsonpath='{range .items[*]}{.metadata.name}: {.status.podIP}{"\n"}{end}'
```

---

## NS1 → NS2 특정 IP 허용

`poc-netpol-1` VM의 IP를 확인한 후 `netpol-allow-from-ns1-ip.yaml`을 수정하여 적용합니다.

```bash
# 1. NS1 VM IP 확인
NS1_VM_IP=$(oc get vmi -n poc-netpol-1 \
  -o jsonpath='{.items[0].status.interfaces[0].ipAddress}')
echo "NS1 VM IP: ${NS1_VM_IP}"

# 2. yaml 파일의 cidr 값 수정 후 적용
#    netpol-allow-from-ns1-ip.yaml 에서 192.168.0.1/32 → 실제 IP/32 로 교체

oc apply -f netpol-allow-from-ns1-ip.yaml

# 3. 적용 확인
oc get networkpolicy -n poc-netpol-2
oc describe networkpolicy allow-from-ns1-vm-ip -n poc-netpol-2
```

---

## 통신 테스트

```bash
# NS1 VM 콘솔 접속
virtctl console poc-vm-1 -n poc-netpol-1

# VM 내부에서 NS2 VM IP로 ping 테스트
# (allow-from-ns1-vm-ip 적용 전: 실패 / 적용 후: 성공)
ping -c 3 <NS2_VM_IP>
curl -v http://<NS2_VM_IP>
```

---

## DNS / API 서버 Egress 허용 (선택)

Deny All 정책으로 인해 DNS 조회 및 클러스터 API 접근이 차단됩니다.
VM에서 외부 도메인 조회나 클러스터 통신이 필요하면 아래 정책을 추가하세요.

```bash
oc apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: poc-netpol-1
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
EOF
```

---

## 롤백

```bash
# NetworkPolicy 삭제
oc delete networkpolicy --all -n poc-netpol-1
oc delete networkpolicy --all -n poc-netpol-2

# VM 삭제
oc delete vm --all -n poc-netpol-1
oc delete vm --all -n poc-netpol-2

# 네임스페이스 삭제
oc delete namespace poc-netpol-1 poc-netpol-2
```
