# OADP (OpenShift API for Data Protection) 실습

OADP를 사용하여 VM을 백업하고 복원하는 실습입니다.

```
VM (OADP Operator 네임스페이스)
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

- OADP Operator 설치 (`00-operator/oadp-operator.md` 참조)
- S3 백엔드: **MinIO Operator** 또는 **ODF Operator** 중 하나 설치
- `setup.sh` 실행 완료 (OADP 오퍼레이터 네임스페이스 자동 감지 → `OADP_NS` 저장)
- `12-oadp.sh` 실행 완료

---

## 구성 개요

DPA, Secret, Backup, Restore 는 모두 **OADP Operator 가 설치된 네임스페이스**(`OADP_NS`)에 배포됩니다.
`setup.sh` 가 오퍼레이터 네임스페이스를 자동 감지하여 `env.conf`의 `OADP_NS` 에 저장합니다.

| 항목 | 값 |
|------|-----|
| DPA 네임스페이스 | `$OADP_NS` (예: `oadp-user1`, `openshift-adp`) |
| cloud-credentials Secret | `$OADP_NS` |
| BackupStorageLocation | `$OADP_NS` |
| Backup / Restore | `$OADP_NS` |
| S3 백엔드 | MinIO 우선, 없으면 ODF MCG |

```
cloud-credentials Secret ($OADP_NS)
  └─ DataProtectionApplication poc-dpa ($OADP_NS)
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
# OADP_NS: setup.sh 자동 감지값 (예: oadp-user1, openshift-adp)
OADP_NS=$(oc get csv -A | grep -i oadp-operator | awk '{print $1}' | head -1)

# 1. cloud-credentials Secret 생성
oc apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cloud-credentials
  namespace: ${OADP_NS}
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
  namespace: ${OADP_NS}
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
  namespace: ${OADP_NS}
spec:
  includedNamespaces:
    - <백업할 VM 네임스페이스>
  storageLocation: default
  ttl: 720h0m0s
  snapshotVolumes: true
EOF

# 백업 상태 확인
oc get backup -n ${OADP_NS}

# 백업 상세 확인
oc describe backup poc-vm-backup -n ${OADP_NS}
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
  namespace: ${OADP_NS}
spec:
  backupName: poc-vm-backup
  includedNamespaces:
    - <복원할 VM 네임스페이스>
  restorePVs: true
EOF

# 복원 상태 확인
oc get restore -n ${OADP_NS}

# 복원된 VM 확인 (복원 대상 네임스페이스 지정)
oc get vm -n <복원할 VM 네임스페이스>
```

---

## BackupStorageLocation 확인

```bash
# BackupStorageLocation 상태 (Available 여야 함)
oc get backupstoragelocation -n ${OADP_NS}

# 상세 확인
oc describe backupstoragelocation -n ${OADP_NS}
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
  namespace: ${OADP_NS}
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
oc get schedule -n ${OADP_NS}
```

---

## 트러블슈팅

```bash
# Velero Pod 로그
oc logs -n ${OADP_NS} -l app.kubernetes.io/name=velero --tail=50

# NodeAgent 로그 (PVC 백업/복원)
oc logs -n ${OADP_NS} daemonset/node-agent --tail=30

# BackupStorageLocation 상세
oc describe backupstoragelocation -n ${OADP_NS}

# DPA 상태 확인
oc get dpa poc-dpa -n ${OADP_NS} -o yaml
```

---

## 롤백

```bash
# Schedule 삭제
oc delete schedule poc-daily-backup -n ${OADP_NS}

# DataProtectionApplication 삭제
oc delete dpa poc-dpa -n ${OADP_NS}

# cloud-credentials Secret 삭제
oc delete secret cloud-credentials -n ${OADP_NS}
```
