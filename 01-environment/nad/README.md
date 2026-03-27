# NAD (NetworkAttachmentDefinition) 구성

## 개요

NAD(NetworkAttachmentDefinition)는 VM이 연결할 수 있는 추가 네트워크를 정의합니다.
NNCP로 생성된 Linux Bridge를 참조하여, VM에 보조 네트워크 인터페이스를 제공합니다.

---

## 사전 조건

- NNCP 구성 완료 (`01-environment/nncp/` 참조)
- Linux Bridge(`${BRIDGE_NAME}`)가 모든 워커 노드에 생성된 상태

---

## 적용 방법

```bash
# 프로젝트 루트에서
source env.conf

cd 01-environment/nad

# Namespace 및 NAD 생성
envsubst < nad-bridge.yaml | oc apply -f -

# 또는 apply.sh 사용
./apply.sh
```

---

## 파일 설명

| 파일 | 설명 |
|------|------|
| `nad-bridge.yaml` | Bridge 기반 NAD (Namespace + NAD) |
| `consoleYamlSample.yaml` | Console에서 직접 적용 가능한 샘플 |
| `apply.sh` | envsubst 변수 치환 후 적용 |

---

## 상태 확인

```bash
# NAD 목록 확인
oc get network-attachment-definitions -n poc-nad

# NAD 상세 확인
oc describe network-attachment-definition poc-bridge-nad -n poc-nad

# NAD를 사용하는 VM 확인
oc get vmi -A -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.networks}{"\n"}{end}'
```

---

## VM에서 NAD 사용

VM의 네트워크 설정에 NAD를 추가합니다:

```yaml
spec:
  template:
    spec:
      networks:
        - name: default
          pod: {}
        # NAD 추가
        - name: secondary
          multus:
            networkName: poc-nad/poc-bridge-nad
      domain:
        devices:
          interfaces:
            - name: default
              masquerade: {}
            # 보조 인터페이스 추가
            - name: secondary
              bridge: {}
```

---

## 네트워크 상태 확인

```bash
# VM 내부에서 인터페이스 확인
oc exec -n <namespace> <virt-launcher-pod> -- ip addr

# VMI 네트워크 인터페이스 상태 확인
oc get vmi <vmi-name> -n <namespace> -o jsonpath='{.status.interfaces}' | python3 -m json.tool

# Bridge에 연결된 VM 확인 (노드에서)
oc debug node/<node-name> -- bridge link show
```

---

## 트러블슈팅

```bash
# NAD 설정 오류 확인
oc describe network-attachment-definition poc-bridge-nad -n poc-nad

# Multus 플러그인 로그 확인
oc logs -n openshift-multus -l app=multus

# VM Pod의 네트워크 설정 확인
oc describe pod <virt-launcher-pod> -n <namespace>
```
