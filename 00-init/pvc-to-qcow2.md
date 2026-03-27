# PVC를 qcow2 이미지로 만드는 방법

OpenShift Virtualization 환경에서 PVC에 저장된 VM 디스크 데이터를 로컬의 qcow2 이미지 파일로 추출하는 방법을 설명합니다.

---

## 방법 1: virtctl 명령어로 직접 다운로드 (가장 권장)

OpenShift Virtualization 전용 CLI 도구인 virtctl을 사용하면 PVC의 데이터를 로컬 파일로 간편하게 스트리밍할 수 있습니다.

### 1. PVC 이름 확인

`openshift-virtualization-os-images` 네임스페이스에서 대상 PVC 이름을 확인합니다.

```bash
oc get pvc -n openshift-virtualization-os-images
```

### 2. 이미지 다운로드

```bash
virtctl image-upload pvc <PVC_NAME> \
  --image-path=./rhel9-extracted.qcow2 \
  --pull-method=http \
  --download \
  -n openshift-virtualization-os-images
```

| 옵션 | 설명 |
|------|------|
| `--download` | PVC의 데이터를 로컬로 가져오겠다는 옵션 |
| `--image-path` | 저장할 로컬 파일 경로 |
| `--pull-method=http` | CDI uploadproxy를 통한 HTTP 스트리밍 방식 |
| `-n` | PVC가 위치한 네임스페이스 |

---

## 방법 2: Pod를 통한 수동 복사

virtctl을 사용할 수 없는 경우, PVC를 마운트한 임시 Pod를 생성하여 `oc cp`로 파일을 추출합니다.

### 1. PVC를 마운트한 임시 Pod 생성

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: pvc-export
  namespace: openshift-virtualization-os-images
spec:
  restartPolicy: Never
  containers:
    - name: exporter
      image: registry.access.redhat.com/ubi9/ubi:latest
      command: ["sleep", "3600"]
      volumeMounts:
        - name: pvc-data
          mountPath: /data
  volumes:
    - name: pvc-data
      persistentVolumeClaim:
        claimName: <PVC_NAME>
EOF
```

### 2. Pod가 Running 상태가 될 때까지 대기

```bash
oc wait pod/pvc-export -n openshift-virtualization-os-images \
  --for=condition=Ready --timeout=60s
```

### 3. 파일 목록 확인 후 복사

```bash
# 파일 목록 확인
oc exec -n openshift-virtualization-os-images pvc-export -- ls -lh /data/

# qcow2 파일 로컬로 복사
oc cp openshift-virtualization-os-images/pvc-export:/data/disk.img ./rhel9-extracted.qcow2
```

### 4. 임시 Pod 삭제

```bash
oc delete pod pvc-export -n openshift-virtualization-os-images
```

---

## 방법 3: VolumeSnapshot + DataVolume export (스냅샷 기반)

CSI 스냅샷을 지원하는 스토리지 환경에서, 스냅샷으로부터 새 PVC를 생성하고 해당 PVC를 방법 1 또는 방법 2로 내보냅니다.

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

# 3. 복원된 PVC를 virtctl로 다운로드
virtctl image-upload pvc rhel9-export-pvc \
  --image-path=./rhel9-extracted.qcow2 \
  --pull-method=http \
  --download \
  -n openshift-virtualization-os-images
```

---

## 참고

- `virtctl` 설치: OpenShift Console > `?` 메뉴 > **Command line tools** 에서 다운로드
- 추출한 qcow2 파일은 `01-environment/custom-image/` 가이드를 참조하여 다시 클러스터에 업로드할 수 있습니다.
