# 내부 이미지 레지스트리 설정 및 VDDK 이미지 Push

## 개요

OpenShift 내부 이미지 레지스트리(포트 5000)를 활성화하고,
VMware VM 마이그레이션에 필요한 VDDK(VMware Virtual Disk Development Kit) 이미지를 push합니다.

---

## 파일 설명

| 파일 | 설명 |
|------|------|
| [`enable-registry.sh`](enable-registry.sh) | 내부 이미지 레지스트리 활성화 스크립트 |
| [`push-vddk.sh`](push-vddk.sh) | VDDK 이미지 내부 레지스트리에 push 스크립트 |

---

## 내부 이미지 레지스트리 활성화

기본적으로 OpenShift 내부 레지스트리는 `Removed` 상태입니다.
PVC를 사용하도록 설정하면 영구 저장이 가능합니다.

```bash
# 현재 레지스트리 상태 확인
oc get configs.imageregistry.operator.openshift.io cluster -o jsonpath='{.spec.managementState}'

# 레지스트리 활성화 (Managed 상태로 변경)
./enable-registry.sh
```

---

## 적용 방법

```bash
# 프로젝트 루트에서
source env.conf

cd 01-environment/image-registry

# 1. 내부 레지스트리 활성화
./enable-registry.sh

# 2. VDDK 이미지 push (VMware 마이그레이션 필요 시)
./push-vddk.sh
```

---

## Red Hat 기본 제공 이미지 위치

OpenShift Virtualization은 다음 위치에서 기본 OS 이미지를 관리합니다:

```bash
# 기본 OS 이미지 DataSource 목록
oc get datasource -n openshift-virtualization-os-images

# 각 이미지의 상태 확인 (Ready 여야 함)
oc get datavolume -n openshift-virtualization-os-images

# 특정 이미지 상세 확인
oc describe datasource rhel9 -n openshift-virtualization-os-images

# 이미지가 저장된 PVC 확인
oc get pvc -n openshift-virtualization-os-images
```

### 기본 이미지 목록

| OS | DataSource 이름 | 용도 |
|----|----------------|------|
| RHEL 9 | rhel9 | Red Hat Enterprise Linux 9 |
| RHEL 8 | rhel8 | Red Hat Enterprise Linux 8 |
| Fedora | fedora | Fedora Linux |
| CentOS Stream 9 | centos-stream9 | CentOS Stream 9 |
| Windows Server 2019 | win2k19 | Windows Server 2019 |
| Windows Server 2022 | win2k22 | Windows Server 2022 |

---

## 내부 레지스트리 접근 정보

```bash
# 내부 레지스트리 서비스 주소
# image-registry.openshift-image-registry.svc:5000

# 외부에서 접근하는 경우 Route 확인
oc get route -n openshift-image-registry

# 레지스트리 인증 (Pod 내부)
# ServiceAccount의 token을 사용하여 자동 인증됨

# 외부에서 로그인 (Route 사용)
REGISTRY_ROUTE=$(oc get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}')
oc login --token=$(oc whoami -t) $REGISTRY_ROUTE
podman login -u $(oc whoami) -p $(oc whoami -t) $REGISTRY_ROUTE
```

---

## 상태 확인

```bash
# 레지스트리 Pod 상태 확인
oc get pods -n openshift-image-registry

# 레지스트리 스토리지 확인
oc get pvc -n openshift-image-registry

# 레지스트리 설정 확인
oc get configs.imageregistry.operator.openshift.io cluster -o yaml

# 이미지 스트림 목록 확인
oc get imagestream -n openshift | head -20

# Push된 VDDK 이미지 확인
oc get imagestream vddk -n openshift
```

---

## CPU / Memory 상태 확인

```bash
# 레지스트리 Pod 리소스 사용량 확인
oc adm top pod -n openshift-image-registry

# 레지스트리 스토리지 사용량 확인
oc get pvc -n openshift-image-registry -o custom-columns="NAME:.metadata.name,CAPACITY:.status.capacity.storage,USED:.status.phase"
```

---

## 트러블슈팅

```bash
# 레지스트리 Pod 로그 확인
oc logs -n openshift-image-registry deployment/image-registry

# 이미지 Push 오류 시 권한 확인
oc get clusterrolebinding | grep registry

# 레지스트리 운영자 로그 확인
oc logs -n openshift-image-registry deployment/cluster-image-registry-operator
```
