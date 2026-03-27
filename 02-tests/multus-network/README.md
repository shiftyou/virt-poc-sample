# Multus 멀티 네트워크 테스트

## 개요

VM에 보조 네트워크 인터페이스를 추가하여 멀티 네트워크 환경을 테스트합니다.
NNCP로 생성한 Bridge와 NAD를 사용하여 VM에 추가 네트워크를 연결합니다.

---

## 사전 조건

- NNCP 구성 완료 (`01-environment/nncp/` 참조)
- NAD 구성 완료 (`01-environment/nad/` 참조)

---

## 적용 방법

```bash
source ../../env.conf
cd 02-tests/multus-network
envsubst < test-vm-multus.yaml | oc apply -f -
```

---

## 파일 설명

| 파일 | 설명 |
|------|------|
| [`namespace.yaml`](namespace.yaml) | poc-multus 네임스페이스 |
| [`test-vm-multus.yaml`](test-vm-multus.yaml) | Pod + Bridge 2개 인터페이스 VM (envsubst 필요) |
| [`apply.sh`](apply.sh) | 적용 스크립트 |

---

## 테스트 절차

```bash
# VM 생성 및 시작
oc apply -f namespace.yaml
envsubst < test-vm-multus.yaml | oc apply -f -
oc patch vm test-multus-vm -n poc-multus \
  --type merge -p '{"spec":{"running":true}}'

# VM 네트워크 인터페이스 확인
oc get vmi test-multus-vm -n poc-multus \
  -o jsonpath='{.status.interfaces}' | python3 -m json.tool

# VM 내부에서 인터페이스 확인
oc exec -n poc-multus \
  $(oc get pod -n poc-multus -l kubevirt.io/domain=test-multus-vm -o name) \
  -- ip addr
```

---

## 상태 확인

```bash
# VMI 네트워크 인터페이스 상태
oc get vmi test-multus-vm -n poc-multus -o yaml | grep -A20 "interfaces:"

# Bridge에 연결된 VM 확인 (노드에서)
oc debug node/<node-name> -- bridge link show

# NAD 확인
oc get network-attachment-definitions -n poc-nad
```

---

## 트러블슈팅

```bash
# Multus 로그 확인
oc logs -n openshift-multus -l app=multus --tail=50

# VM Pod의 네트워크 annotation 확인
oc describe pod -n poc-multus \
  $(oc get pod -n poc-multus -l kubevirt.io/domain=test-multus-vm -o name)
```
