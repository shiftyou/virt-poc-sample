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

#### 3. VMExport 상태 확인

`Ready` 상태가 된 것을 확인한 후 다운로드합니다.

```bash
oc get vmexport rhel9-export -n <NAMESPACE>
```

출력 예시:
```
NAME            SOURCEKIND               SOURCENAME   PHASE   READY
rhel9-export    PersistentVolumeClaim    <PVC_NAME>   Ready   true
```

`READY`가 `true` 가 아니면 VM이 실행 중인지 확인하고 중지합니다 (아래 트러블슈팅 참고).

#### 4. 이미지 다운로드

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

#### 5. VMExport 삭제 (정리)

```bash
virtctl vmexport delete rhel9-export -n <NAMESPACE>
```

#### ⚠️ 트러블슈팅: `waiting for VM Export ... status to be ready` 무한 반복

`virtctl vmexport download` 실행 시 아래 메시지가 반복되면서 멈추는 경우:

```
waiting for VM Export rhel9-poc-vm status to be ready...
waiting for VM Export rhel9-poc-vm status to be ready...
```

**원인**: PVC가 실행 중인 VM에 마운트되어 있으면, export Pod가 PVC에 접근하지 못해 `Ready` 상태가 되지 않습니다.
특히 PVC의 accessMode가 `ReadWriteOnce(RWO)` 인 경우 VM이 점유하는 동안 다른 Pod가 동시에 마운트할 수 없습니다.

**해결 방법 1: VM을 먼저 중지 (권장)**

```bash
# VM 중지
virtctl stop <VM_NAME> -n <NAMESPACE>

# VM이 완전히 중지될 때까지 대기
oc wait vm/<VM_NAME> -n <NAMESPACE> \
  --for=jsonpath='{.status.printableStatus}'=Stopped --timeout=120s

# VMExport 재생성 후 다운로드
virtctl vmexport delete rhel9-export -n <NAMESPACE>
virtctl vmexport create rhel9-export --pvc=<PVC_NAME> -n <NAMESPACE>
virtctl vmexport download rhel9-export --output=./rhel9-extracted.qcow2 -n <NAMESPACE>
```

**해결 방법 2: export 상태 직접 확인**

```bash
# VMExport 상태 확인
oc get virtualmachineexport -n <NAMESPACE>
oc describe virtualmachineexport rhel9-export -n <NAMESPACE>

# export Pod 확인 (export Pod가 생성됐는지)
oc get pods -n <NAMESPACE> | grep virt-export
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

## Part 2: qcow2 → 클러스터 전체에서 VM 부팅 이미지로 등록

로컬 qcow2 파일을 `openshift-virtualization-os-images` 네임스페이스에 업로드하고 DataSource로 등록합니다.
DataSource를 이 네임스페이스에 두면 **CDI가 VM 생성 시 자동으로 해당 네임스페이스에 PVC를 클론**하므로,
어떤 네임스페이스에서도 동일한 이미지로 VM을 생성할 수 있습니다.

```
rhel9-poc-vm.qcow2 (로컬)
        │  virtctl image-upload
        ▼
PVC: rhel9-golden-poc  (openshift-virtualization-os-images)
        │  DataSource 생성
        ▼
DataSource: rhel9-golden-poc  (openshift-virtualization-os-images)
        │  VM 생성 시 CDI 자동 클론
        ▼
PVC: <vm-name>-rootdisk  (어느 네임스페이스든)
```

---

### 1단계: qcow2 업로드

```bash
virtctl image-upload \
  --image-path=rhel9-poc-vm.qcow2 \
  --pvc-name=rhel9-golden-poc \
  --pvc-size=30Gi \
  --storage-class=ocs-storagecluster-ceph-rbd-virtualization \
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
oc get pvc rhel9-golden-poc -n openshift-virtualization-os-images
```

---

### 2단계: DataSource 생성

업로드한 PVC를 DataSource로 등록합니다.
DataSource가 있어야 OpenShift Virtualization UI의 **부팅 소스** 목록에 나타나고,
다른 네임스페이스에서 VM 생성 시 CDI가 이 DataSource를 참조하여 PVC를 자동 클론합니다.

```bash
cat <<'EOF' | oc apply -f -
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataSource
metadata:
  name: rhel9-golden-poc
  namespace: openshift-virtualization-os-images
spec:
  source:
    pvc:
      name: rhel9-golden-poc
      namespace: openshift-virtualization-os-images
EOF
```

DataSource 상태를 확인합니다. `READY=true` 여야 합니다.

```bash
oc get datasource rhel9-golden-poc -n openshift-virtualization-os-images
```

출력 예시:
```
NAME                READY
rhel9-golden-poc    true
```

---

### 3단계: 어느 네임스페이스에서든 VM 생성

VM의 `dataVolumeTemplates`에서 `sourceRef`로 DataSource를 참조합니다.
CDI가 VM이 생성되는 네임스페이스로 PVC를 **자동으로 클론**합니다.

```bash
cat <<'EOF' | oc apply -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: my-rhel9-vm
  namespace: my-project          # 어떤 네임스페이스든 가능
spec:
  running: false
  template:
    spec:
      domain:
        cpu:
          cores: 2
        memory:
          guest: 4Gi
        devices:
          disks:
            - name: rootdisk
              disk:
                bus: virtio
      volumes:
        - name: rootdisk
          dataVolume:
            name: my-rhel9-vm-rootdisk
  dataVolumeTemplates:
    - apiVersion: cdi.kubevirt.io/v1beta1
      kind: DataVolume
      metadata:
        name: my-rhel9-vm-rootdisk
      spec:
        sourceRef:
          kind: DataSource
          name: rhel9-golden-poc                      # DataSource 이름
          namespace: openshift-virtualization-os-images
        storage:
          resources:
            requests:
              storage: 30Gi
EOF
```

VM 생성 후 클론 진행 상황을 확인합니다.

```bash
# DataVolume 클론 상태 확인
oc get datavolume my-rhel9-vm-rootdisk -n my-project

# 클론 완료 후 VM 시작
virtctl start my-rhel9-vm -n my-project
```

---

## 참고

- `virtctl` 설치: OpenShift Console > `?` 메뉴 > **Command line tools** 에서 다운로드
- 커스텀 이미지 업로드 스크립트(대화형): `01-environment/custom-image/upload-image.sh`
- StorageClass는 `oc get storageclass` 로 확인하세요.
