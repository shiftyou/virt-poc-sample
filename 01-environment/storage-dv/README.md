# DataVolume + StorageProfile 테스트

## 개요

OpenShift Virtualization의 DataVolume(DV)과 StorageProfile을 사용하여
VM 디스크를 생성하고 관리하는 방법을 테스트합니다.

- **DataVolume**: VM 디스크 볼륨을 선언적으로 생성/관리
- **StorageProfile**: 스토리지 클래스의 접근 모드와 볼륨 모드를 설정

---

## 사전 조건

- OpenShift Virtualization 설치 완료
- 스토리지 클래스 사용 가능

---

## 적용 방법

```bash
source ../../env.conf
cd 01-environment/storage-dv
./apply.sh
```

---

## 파일 설명

| 파일 | 설명 |
|------|------|
| [`namespace.yaml`](namespace.yaml) | poc-storage-dv 네임스페이스 |
| [`storageprofile-patch.yaml`](storageprofile-patch.yaml) | StorageProfile RWX+Block / RWO+Filesystem 설정 |
| [`datavolume.yaml`](datavolume.yaml) | Fedora + RHEL9 DataVolume 예시 |
| [`apply.sh`](apply.sh) | 적용 스크립트 |

---

## StorageProfile 확인

```bash
# 스토리지 프로파일 목록
oc get storageprofile

# 특정 스토리지 프로파일 상세 확인
oc get storageprofile <storage-class-name> -o yaml

# CDI에서 인식한 스토리지 클래스 목록
oc get cdi -n openshift-cnv -o yaml | grep -A5 "storageClass"
```

---

## DataVolume 생성 방법

### 방법 1: URL에서 이미지 임포트

```bash
oc apply -f - <<EOF
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: imported-image
  namespace: poc-storage-dv
spec:
  source:
    http:
      url: "https://example.com/image.qcow2"
  storage:
    resources:
      requests:
        storage: 20Gi
EOF
```

### 방법 2: 기존 PVC에서 복제

```bash
oc apply -f - <<EOF
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: cloned-dv
  namespace: poc-storage-dv
spec:
  source:
    pvc:
      namespace: openshift-virtualization-os-images
      name: <source-pvc-name>
  storage:
    resources:
      requests:
        storage: 20Gi
EOF
```

### 방법 3: DataSource에서 생성 (권장)

```bash
oc apply -f datavolume.yaml
```

---

## 상태 확인

```bash
# DataVolume 상태 확인 (Succeeded여야 함)
oc get datavolume -n poc-storage-dv

# DataVolume 상세 확인 (진행률 포함)
oc describe datavolume <dv-name> -n poc-storage-dv

# 생성된 PVC 확인
oc get pvc -n poc-storage-dv

# StorageProfile 확인
oc get storageprofile

# CDI Pod 상태 (임포트 작업)
oc get pods -n openshift-cnv | grep importer
```

---

## CPU / Memory / Storage 사용량 확인

```bash
# 네임스페이스별 PVC 사용량
oc get pvc -n poc-storage-dv \
  -o custom-columns="NAME:.metadata.name,CAPACITY:.status.capacity.storage,STATUS:.status.phase"

# 노드 디스크 사용량 (노드에서)
oc debug node/<node-name> -- df -h /var

# 스토리지 클래스별 사용량
oc get pv -o custom-columns="NAME:.metadata.name,CAPACITY:.spec.capacity.storage,SC:.spec.storageClassName,STATUS:.status.phase"
```

---

## 트러블슈팅

```bash
# DataVolume 임포트 실패 시 importer Pod 로그 확인
oc logs -n poc-storage-dv \
  $(oc get pod -n poc-storage-dv -l cdi.kubevirt.io=importer -o name) --tail=50

# StorageProfile 미인식 문제
oc describe storageprofile <storage-class-name>

# CDI 설정 확인
oc get cdi -n openshift-cnv -o yaml
```
