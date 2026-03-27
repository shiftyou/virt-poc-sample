# OpenShift Virtualization Operator 설치

## 개요

OpenShift Virtualization은 OpenShift Container Platform에서 가상 머신(VM)을 생성하고 관리할 수 있게 해주는 기능입니다.
KubeVirt 기반으로 동작하며, VM을 Pod처럼 관리합니다.

---

## 사전 조건

- OpenShift 4.20 이상
- cluster-admin 권한
- 워커 노드에 가상화 지원 CPU (Intel VT-x 또는 AMD-V)
- (airgap) 미러 레지스트리 구성 완료

---

## 설치 방법

### 방법 1: OpenShift Console (Web UI)

1. **Operators > OperatorHub** 메뉴로 이동
2. `OpenShift Virtualization` 검색
3. **Red Hat OpenShift Virtualization** 선택
4. `Install` 클릭
5. 설정:
   - Update channel: `stable`
   - Installation mode: `All namespaces on the cluster`
   - Installed Namespace: `openshift-cnv`
6. `Install` 클릭 후 완료 대기

### 방법 2: CLI (YAML)

```bash
# 1. Namespace 생성
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-cnv
  labels:
    openshift.io/cluster-monitoring: "true"
EOF

# 2. OperatorGroup 생성
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kubevirt-hyperconverged-group
  namespace: openshift-cnv
spec:
  targetNamespaces:
    - openshift-cnv
EOF

# 3. Subscription 생성
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: hco-operatorhub
  namespace: openshift-cnv
spec:
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  name: kubevirt-hyperconverged
  startingCSV: kubevirt-hyperconverged-operator.v4.20.0
  channel: "stable"
EOF
```

### 4. HyperConverged CR 생성 (Operator 설치 후)

```bash
oc apply -f - <<EOF
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
spec: {}
EOF
```

---

## 설치 확인

```bash
# Operator 설치 상태 확인
oc get csv -n openshift-cnv

# HyperConverged 상태 확인 (Available이 True여야 함)
oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv -o jsonpath='{.status.conditions}' | python3 -m json.tool

# KubeVirt 컴포넌트 Pod 확인
oc get pods -n openshift-cnv

# 노드 가상화 지원 확인
oc get nodes -o custom-columns="NODE:.metadata.name,CPU-MANAGER:.status.allocatable.cpu,SCHEDULABLE:.spec.unschedulable"
```

---

## 기본 이미지 위치

Red Hat이 제공하는 기본 VM 이미지는 다음 위치에서 확인할 수 있습니다:

```bash
# DataSource 목록 확인 (기본 이미지 소스)
oc get datasource -n openshift-virtualization-os-images

# 사용 가능한 이미지 확인
oc get datavolume -n openshift-virtualization-os-images

# 부트 소스 이미지 상태 확인
oc get cdi -n openshift-cnv
```

### 기본 제공 이미지 종류

| 이미지 | DataSource 이름 |
|--------|----------------|
| RHEL 9 | rhel9 |
| RHEL 8 | rhel8 |
| Fedora | fedora |
| CentOS Stream 9 | centos-stream9 |
| Windows Server 2019 | win2k19 |
| Windows Server 2022 | win2k22 |

```bash
# 특정 이미지 상태 확인
oc get datasource rhel9 -n openshift-virtualization-os-images -o yaml
```

---

## CPU / Memory / Network 상태 확인

```bash
# VM 목록 확인
oc get vm -A

# VMI(VirtualMachineInstance) 확인
oc get vmi -A

# VM CPU/Memory 사용량 확인
oc adm top pod -n <vm-namespace> --containers

# VM 네트워크 인터페이스 확인 (VMI 상세)
oc get vmi <vmi-name> -n <namespace> -o jsonpath='{.status.interfaces}' | python3 -m json.tool

# 노드별 VM 분포 확인
oc get vmi -A -o custom-columns="NAMESPACE:.metadata.namespace,NAME:.metadata.name,NODE:.status.nodeName,PHASE:.status.phase"
```

---

## 트러블슈팅

```bash
# HyperConverged 이벤트 확인
oc describe hyperconverged kubevirt-hyperconverged -n openshift-cnv

# Operator Pod 로그 확인
oc logs -n openshift-cnv deployment/hco-operator

# 가상화 기능 지원 여부 확인
oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.allocatable}{"\n"}{end}'
```
