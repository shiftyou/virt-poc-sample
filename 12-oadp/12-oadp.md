# OADP (OpenShift API for Data Protection) 실습

OADP를 사용하여 VM을 백업하고 복원하는 실습입니다.

```
VM (openshift-adp 네임스페이스)
  │  Backup CR 생성
  ▼
OADP (Velero)
  └─ VM 스냅샷 + PVC 데이터
       │  S3 (MinIO 또는 ODF MCG) 저장
       ▼
  Backup 완료

복원:
  Restore CR 생성 → OADP → VM 재생성
```

---

## 사전 조건

- OADP Operator 설치 (`00-operator/oadp-operator.md` 참조) — **`openshift-adp` 네임스페이스에 설치**
- S3 백엔드: **MinIO Operator** 또는 **ODF Operator** 중 하나 설치
- `setup.sh` 실행 완료 (MinIO/ODF 자동 감지 및 `env.conf` 저장)
- `12-oadp.sh` 실행 완료

---

## 구성 개요

| 항목 | 값 |
|------|-----|
| DPA 네임스페이스 | `openshift-adp` |
| cloud-credentials Secret | `openshift-adp` |
| BackupStorageLocation | `openshift-adp` |
| Backup / Restore | `openshift-adp` |
| S3 백엔드 | MinIO 우선, 없으면 ODF MCG |

```
cloud-credentials Secret (openshift-adp)
  └─ DataProtectionApplication poc-dpa (openshift-adp)
       └─ BackupStorageLocation default
            │
            ├─ Backup CR   → S3 버킷에 저장
            └─ Restore CR  → S3 버킷에서 복원
```

---

## 백엔드별 S3 변수

`setup.sh` 실행 시 MinIO/ODF 자동 감지 후 `env.conf`에 저장됩니다.

| 변수 | MinIO | ODF (NooBaa MCG) |
|------|-------|-----------------|
| `S3_ENDPOINT` | MinIO 서비스 URL | NooBaa MCG S3 URL |
| `S3_BUCKET` | `MINIO_BUCKET` | `ODF_S3_BUCKET` |
| `S3_ACCESS_KEY` | `MINIO_ACCESS_KEY` | noobaa-admin secret |
| `S3_SECRET_KEY` | `MINIO_SECRET_KEY` | noobaa-admin secret |
| `S3_REGION` | `minio` | `localstorage` |

---

## DataProtectionApplication 설정

`12-oadp.sh`가 자동으로 생성·적용합니다. 수동 적용 시 아래를 참고하세요.

```bash
# 1. cloud-credentials Secret 생성 (openshift-adp)
oc apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cloud-credentials
  namespace: openshift-adp
stringData:
  cloud: |
    [default]
    aws_access_key_id=${S3_ACCESS_KEY}
    aws_secret_access_key=${S3_SECRET_KEY}
EOF

# 2. DataProtectionApplication 생성
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
        - csi
        - openshift
        - aws
        - kubevirt
      disableFsBackup: false
      featureFlags:
        - EnableCSI
  logFormat: text
  backupLocations:
    - velero:
        provider: aws
        default: true
        objectStorage:
          bucket: ${S3_BUCKET}
          prefix: velero
        config:
          profile: default
          region: ${S3_REGION}
          s3ForcePathStyle: "true"
          s3Url: ${S3_ENDPOINT}
          checksumAlgorithm: ""
        credential:
          key: cloud
          name: cloud-credentials
EOF
```

---

## VolumeSnapshotClass (CSI 스냅샷)

`12-oadp.sh`가 클러스터의 CSI 드라이버를 자동 감지하여 `volumesnapshotclass.yaml`을 생성합니다.
CSI 스냅샷을 사용하는 경우 직접 적용하세요.

```bash
# 생성된 파일 확인 후 적용
oc apply -f volumesnapshotclass.yaml

# CSI 드라이버 목록 확인
oc get csidrivers
```

---

## VM 백업

```bash
# OADP Operator 네임스페이스의 VM 백업 (백업 대상 네임스페이스는 includedNamespaces 에 지정)
oc apply -f - <<EOF
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: poc-vm-backup
  namespace: openshift-adp
spec:
  includedNamespaces:
    - <백업할 VM 네임스페이스>
  storageLocation: default
  ttl: 720h0m0s
  snapshotVolumes: true
EOF

# 백업 상태 확인
oc get backup -n openshift-adp

# 백업 상세 확인
oc describe backup poc-vm-backup -n openshift-adp
```

---

## VM 복원

```bash
# 백업에서 복원
oc apply -f - <<EOF
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: poc-vm-restore
  namespace: openshift-adp
spec:
  backupName: poc-vm-backup
  includedNamespaces:
    - <복원할 VM 네임스페이스>
  restorePVs: true
EOF

# 복원 상태 확인
oc get restore -n openshift-adp

# 복원된 VM 확인 (복원 대상 네임스페이스 지정)
oc get vm -n <복원할 VM 네임스페이스>
```

---

## BackupStorageLocation 확인

```bash
# BackupStorageLocation 상태 (Available 여야 함)
oc get backupstoragelocation -n openshift-adp

# 상세 확인
oc describe backupstoragelocation -n openshift-adp
```

---

## Schedule — 정기 백업

```bash
# 매일 새벽 2시 자동 백업
oc apply -f - <<EOF
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: poc-daily-backup
  namespace: openshift-adp
spec:
  schedule: "0 2 * * *"
  template:
    includedNamespaces:
      - <백업할 VM 네임스페이스>
    storageLocation: default
    ttl: 168h0m0s
    snapshotVolumes: true
EOF

# Schedule 확인
oc get schedule -n openshift-adp
```

---

## 트러블슈팅

```bash
# Velero Pod 로그
oc logs -n openshift-adp -l app.kubernetes.io/name=velero --tail=50

# NodeAgent 로그 (PVC 백업/복원)
oc logs -n openshift-adp daemonset/node-agent --tail=30

# BackupStorageLocation 상세
oc describe backupstoragelocation -n openshift-adp

# DPA 상태 확인
oc get dpa poc-dpa -n openshift-adp -o yaml
```

---

## 롤백

```bash
# Schedule 삭제
oc delete schedule poc-daily-backup -n openshift-adp

# DataProtectionApplication 삭제
oc delete dpa poc-dpa -n openshift-adp

# cloud-credentials Secret 삭제
oc delete secret cloud-credentials -n openshift-adp
```
