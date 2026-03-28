# OADP (OpenShift API for Data Protection) 실습

OADP를 사용하여 VM을 백업하고 복원하는 실습입니다.

```
VM (poc-oadp 네임스페이스)
  │  Backup CR 생성
  ▼
OADP (Velero)
  └─ VM 스냅샷 + PVC 데이터
       │  S3 (MinIO) 저장
       ▼
  Backup 완료

복원:
  Restore CR 생성 → OADP → VM 재생성
```

---

## 사전 조건

- OADP Operator 설치 (`00-operator/oadp-operator.md` 참조)
- MinIO 또는 S3 호환 스토리지 준비
- `env.conf`에 `MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY`, `MINIO_ENDPOINT`, `MINIO_BUCKET` 설정
- `14-oadp.sh` 실행 완료

---

## 구성 개요

```
DataProtectionApplication (OADP 설정)
  └─ BackupStorageLocation (MinIO S3)
  └─ VolumeSnapshotLocation (CSI)
       │
       ├─ Backup CR → 네임스페이스 전체 백업
       └─ Restore CR → 백업에서 복원
```

---

## DataProtectionApplication 설정

```bash
source env.conf

# MinIO 자격증명 Secret 생성
oc create secret generic cloud-credentials \
  -n openshift-adp \
  --from-literal=cloud="[default]
aws_access_key_id=${MINIO_ACCESS_KEY}
aws_secret_access_key=${MINIO_SECRET_KEY}
" 2>/dev/null || \
oc create secret generic cloud-credentials \
  -n openshift-adp \
  --from-literal=cloud="[default]
aws_access_key_id=${MINIO_ACCESS_KEY}
aws_secret_access_key=${MINIO_SECRET_KEY}
" --dry-run=client -o yaml | oc apply -f -

# DataProtectionApplication 생성
oc apply -f - <<EOF
apiVersion: oadp.openshift.io/v1alpha1
kind: DataProtectionApplication
metadata:
  name: poc-dpa
  namespace: openshift-adp
spec:
  configuration:
    velero:
      defaultPlugins:
        - openshift
        - aws
        - kubevirt
      resourceTimeout: 10m
    nodeAgent:
      enable: true
      uploaderType: kopia
  backupLocations:
    - name: default
      velero:
        provider: aws
        default: true
        objectStorage:
          bucket: ${MINIO_BUCKET}
          prefix: velero
        config:
          region: minio
          s3ForcePathStyle: "true"
          s3Url: ${MINIO_ENDPOINT}
          insecureSkipTLSVerify: "true"
        credential:
          key: cloud
          name: cloud-credentials
  snapshotLocations:
    - name: default
      velero:
        provider: aws
        config:
          region: minio
EOF
```

---

## VM 백업

### 네임스페이스 전체 백업

```bash
# poc-oadp 네임스페이스의 모든 VM 백업
oc apply -f - <<EOF
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: poc-vm-backup-$(date +%Y%m%d-%H%M)
  namespace: openshift-adp
spec:
  includedNamespaces:
    - poc-oadp
  storageLocation: default
  ttl: 720h0m0s
  snapshotMoveData: true
EOF
```

### 백업 상태 확인

```bash
# 백업 목록 확인
oc get backup -n openshift-adp

# 백업 상세 확인
oc describe backup poc-vm-backup -n openshift-adp

# 백업 로그 확인
oc logs -n openshift-adp deployment/openshift-adp-velero --tail=50
```

---

## VM 복원

```bash
# 백업에서 복원
oc apply -f - <<EOF
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: poc-vm-restore-$(date +%Y%m%d-%H%M)
  namespace: openshift-adp
spec:
  backupName: <백업_이름>
  includedNamespaces:
    - poc-oadp
  restorePVs: true
EOF

# 복원 상태 확인
oc get restore -n openshift-adp

# 복원된 VM 확인
oc get vm -n poc-oadp
```

---

## BackupStorageLocation 확인

```bash
# BackupStorageLocation 상태 (Available 여야 함)
oc get backupstoragelocation -n openshift-adp

# MinIO 연결 테스트
oc exec -n openshift-adp deployment/openshift-adp-velero -- \
  velero backup-location get
```

---

## Schedule — 정기 백업

```bash
# 매일 새벽 2시 자동 백업
oc apply -f - <<'EOF'
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: poc-daily-backup
  namespace: openshift-adp
spec:
  schedule: "0 2 * * *"
  template:
    includedNamespaces:
      - poc-oadp
    storageLocation: default
    ttl: 168h0m0s
    snapshotMoveData: true
EOF

# Schedule 확인
oc get schedule -n openshift-adp
```

---

## 트러블슈팅

```bash
# OADP Controller 로그
oc logs -n openshift-adp deployment/openshift-adp-velero --tail=50

# NodeAgent 로그 (PVC 백업/복원)
oc logs -n openshift-adp daemonset/node-agent --tail=30

# BackupStorageLocation 상세
oc describe backupstoragelocation default -n openshift-adp

# Velero CLI (Pod 내부에서)
oc exec -n openshift-adp deployment/openshift-adp-velero -- \
  velero backup describe <백업_이름> --details
```

---

## 롤백

```bash
# Schedule 삭제
oc delete schedule poc-daily-backup -n openshift-adp

# DataProtectionApplication 삭제
oc delete dpa poc-dpa -n openshift-adp

# 네임스페이스 삭제
oc delete namespace poc-oadp
```
