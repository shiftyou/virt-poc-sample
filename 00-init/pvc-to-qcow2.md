# qcow2 이미지와 openshift-virtualization-os-images 간 변환 가이드

OpenShift Virtualization 환경에서 PVC의 VM 디스크를 로컬 qcow2 파일로 추출하거나,
로컬 qcow2 파일을 `openshift-virtualization-os-images` 네임스페이스에 업로드하여 VM 부팅 이미지로 등록하는 방법을 설명합니다.

---

## Part 1: PVC → qcow2 (다운로드)

### 방법 1: virtctl vmexport로 다운로드 (권장)

`virtctl image-upload`는 업로드 전용 명령입니다. PVC를 로컬로 내보내려면 `virtctl vmexport`를 사용합니다.
(`--pull-method`, `--download` 플래그는 `image-upload`에 존재하지 않습니다.)

#### 1. PVC 이름 확인

```bash
oc get pvc -n <NAMESPACE>
```

#### 2. VMExport 생성

```bash
virtctl vmexport create rhel9-export \
  --pvc=<PVC_NAME> \
  -n <NAMESPACE>
```

#### 3. 이미지 다운로드

```bash
virtctl vmexport download rhel9-export \
  --output=./rhel9-extracted.qcow2 \
  -n <NAMESPACE>
```

| 옵션 | 설명 |
|------|------|
| `create` | 내보내기 세션 생성 |
| `download` | 내보내기 세션에서 로컬로 파일 다운로드 |
| `--output` | 저장할 로컬 파일 경로 |
| `-n` | PVC가 위치한 네임스페이스 |

#### 4. VMExport 삭제 (정리)

```bash
virtctl vmexport delete rhel9-export -n <NAMESPACE>
```

---

### 방법 2: VolumeSnapshot + DataVolume export (스냅샷 기반)

CSI 스냅샷을 지원하는 스토리지 환경에서, 스냅샷으로부터 새 PVC를 생성하고 해당 PVC를 방법 1로 내보냅니다.

```bash
# 1. 스냅샷 생성
cat <<EOF | oc apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: rhel9-snapshot
  namespace: openshift-virtualization-os-images
spec:
  source:
    persistentVolumeClaimName: <PVC_NAME>
EOF

# 2. 스냅샷으로부터 PVC 복원
cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: rhel9-export-pvc
  namespace: openshift-virtualization-os-images
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 30Gi
  dataSource:
    name: rhel9-snapshot
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
EOF

# 3. 복원된 PVC를 virtctl vmexport로 다운로드
virtctl vmexport create rhel9-export --pvc=rhel9-export-pvc -n openshift-virtualization-os-images
virtctl vmexport download rhel9-export --output=./rhel9-extracted.qcow2 -n openshift-virtualization-os-images
virtctl vmexport delete rhel9-export -n openshift-virtualization-os-images
```

---

## Part 2: qcow2 → openshift-virtualization-os-images (업로드)

로컬 qcow2 파일을 클러스터에 업로드하여 VM 부팅 이미지로 등록합니다.
업로드 후 DataSource를 생성하면 VM 생성 시 부팅 이미지로 선택할 수 있습니다.

### 1단계: virtctl로 qcow2 업로드

```bash
IMAGE_NAME=my-rhel9          # 등록할 이미지 이름 (소문자, 하이픈 허용)
IMAGE_FILE=./rhel9.qcow2     # 업로드할 로컬 qcow2 파일 경로
DISK_SIZE=30Gi               # PVC 크기 (이미지보다 충분히 크게)
STORAGE_CLASS=ocs-storagecluster-ceph-rbd-virtualization

virtctl image-upload \
  --image-path="${IMAGE_FILE}" \
  --pvc-name="${IMAGE_NAME}" \
  --pvc-size="${DISK_SIZE}" \
  --storage-class="${STORAGE_CLASS}" \
  --access-mode=ReadWriteMany \
  --block-volume \
  -n openshift-virtualization-os-images \
  --insecure
```

| 옵션 | 설명 |
|------|------|
| `--pvc-name` | 생성할 PVC 이름 |
| `--pvc-size` | PVC 크기 (이미지 파일보다 커야 함) |
| `--storage-class` | 사용할 StorageClass (RWX 지원 필요) |
| `--access-mode=ReadWriteMany` | 라이브 마이그레이션을 위해 RWX 권장 |
| `--block-volume` | Block 모드 PVC 생성 (성능 향상) |
| `--insecure` | 자체 서명 인증서 환경에서 TLS 검증 생략 |

업로드 완료 후 PVC 상태를 확인합니다.

```bash
oc get pvc "${IMAGE_NAME}" -n openshift-virtualization-os-images
```

---

### 2단계: DataSource 생성

업로드한 PVC를 VM 부팅 이미지로 사용할 수 있도록 DataSource를 생성합니다.
DataSource가 있어야 OpenShift Virtualization UI의 **부팅 소스** 목록에 나타납니다.

```bash
IMAGE_NAME=my-rhel9

cat <<EOF | oc apply -f -
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataSource
metadata:
  name: ${IMAGE_NAME}
  namespace: openshift-virtualization-os-images
spec:
  source:
    pvc:
      name: ${IMAGE_NAME}
      namespace: openshift-virtualization-os-images
EOF
```

DataSource 상태를 확인합니다. `Ready` 상태여야 합니다.

```bash
oc get datasource "${IMAGE_NAME}" -n openshift-virtualization-os-images
```

---

### 3단계: VM 생성 시 이미지 사용

등록된 DataSource를 VM의 `dataVolumeTemplates`에서 참조합니다.

```yaml
dataVolumeTemplates:
  - apiVersion: cdi.kubevirt.io/v1beta1
    kind: DataVolume
    metadata:
      name: my-vm-rootdisk
    spec:
      sourceRef:
        kind: DataSource
        name: my-rhel9                           # 등록한 DataSource 이름
        namespace: openshift-virtualization-os-images
      storage:
        resources:
          requests:
            storage: 30Gi
```

---

## 참고

- `virtctl` 설치: OpenShift Console > `?` 메뉴 > **Command line tools** 에서 다운로드
- 커스텀 이미지 업로드 스크립트(대화형): `01-environment/custom-image/upload-image.sh`
- StorageClass는 `oc get storageclass` 로 확인하세요.
