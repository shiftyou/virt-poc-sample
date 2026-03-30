# OADP (OpenShift API for Data Protection) 실습

OADP를 사용하여 VM을 백업하고 복원하는 실습입니다.

```
VM (백업 대상 네임스페이스)
  │  Backup CR 생성
  ▼
OADP (Velero) — openshift-adp 네임스페이스
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
- S3 백엔드: **MinIO 커뮤니티 버전** 배포 또는 **ODF Operator** 설치 (아래 MinIO 설치 가이드 참조)
- `setup.sh` 실행 완료 (MinIO/ODF 자동 감지 및 `env.conf` 저장)
- `12-oadp.sh` 실행 완료

---

## MinIO 커뮤니티 버전 설치

Operator 없이 단순 Deployment로 MinIO를 배포하는 방법입니다.
ODF 없이 빠르게 S3 백엔드를 구성할 때 사용합니다.

### 1. Namespace 및 SCC 설정

```bash
oc new-project minio

# MinIO 컨테이너는 /data 디렉토리에 임의 UID로 쓰기가 필요 — anyuid 부여
oc adm policy add-scc-to-user anyuid -z default -n minio
```

### 2. 리소스 배포

```bash
oc apply -f - <<'EOF'
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: minio-pvc
  namespace: minio
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  namespace: minio
spec:
  replicas: 1
  selector:
    matchLabels:
      app: minio
  template:
    metadata:
      labels:
        app: minio
    spec:
      containers:
        - name: minio
          image: quay.io/minio/minio:latest
          args:
            - server
            - /data
            - --console-address
            - ":9001"
          env:
            - name: MINIO_ROOT_USER
              value: "minioadmin"
            - name: MINIO_ROOT_PASSWORD
              value: "minioadmin"
          ports:
            - containerPort: 9000
              name: api
            - containerPort: 9001
              name: console
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: minio-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: minio
  namespace: minio
spec:
  selector:
    app: minio
  ports:
    - name: api
      port: 9000
      targetPort: 9000
    - name: console
      port: 9001
      targetPort: 9001
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: minio-api
  namespace: minio
spec:
  to:
    kind: Service
    name: minio
  port:
    targetPort: api
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: minio-console
  namespace: minio
spec:
  to:
    kind: Service
    name: minio
  port:
    targetPort: console
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF
```

### 3. 기동 확인

```bash
oc get pods -n minio
# NAME                     READY   STATUS    RESTARTS   AGE
# minio-xxxxxxxxx-xxxxx    1/1     Running   0          1m

oc get route -n minio
# NAME            HOST/PORT                              ...
# minio-api       minio-api-minio.apps.cluster.com       ...
# minio-console   minio-console-minio.apps.cluster.com   ...
```

### 4. 버킷 생성

#### 방법 A — MinIO Console (웹 UI)

1. `https://minio-console-minio.apps.<cluster-domain>` 접속
2. ID: `minioadmin` / PW: `minioadmin` 로 로그인
3. **Buckets → Create Bucket** → 이름: `velero-backups`

#### 방법 B — mc 클라이언트 (CLI)

```bash
# mc 설치 (bastion 또는 로컬)
curl -sO https://dl.min.io/client/mc/release/linux-amd64/mc
chmod +x mc && mv mc /usr/local/bin/

# MinIO API Route 주소 확인
MINIO_API=$(oc get route minio-api -n minio -o jsonpath='{.status.ingress[0].host}')

# alias 등록
mc alias set poc https://${MINIO_API} minioadmin minioadmin --insecure

# 버킷 생성
mc mb poc/velero-backups --insecure

# 확인
mc ls poc --insecure
```

### 5. env.conf 수동 설정

`setup.sh`가 MinIO를 감지하지 못한 경우 아래 값을 `env.conf`에 직접 추가합니다.

```bash
MINIO_INSTALLED=true
MINIO_ENDPOINT=https://minio-api-minio.apps.<cluster-domain>
MINIO_ACCESS_KEY=minioadmin
MINIO_SECRET_KEY=minioadmin
MINIO_BUCKET=velero-backups
```

이후 `13-oadp.sh`를 실행하면 이 값으로 DPA가 구성됩니다.

---

## 구성 개요

| 항목 | 값 |
|------|-----|
| OADP / DPA 네임스페이스 | `openshift-adp` (없으면 `OADP_NS` 감지값) |
| cloud-credentials Secret | `openshift-adp` |
| BackupStorageLocation | `openshift-adp` |
| Backup / Restore | `openshift-adp` |
| S3 백엔드 | MinIO 우선, 없으면 ODF MCG |

```
OBC obc-backups (openshift-adp) — ODF 백엔드 시 자동 생성
  └─ cloud-credentials Secret (openshift-adp)
       └─ DataProtectionApplication poc-dpa (openshift-adp)
            └─ BackupStorageLocation default
                 │
                 ├─ Backup CR   → S3 버킷에 저장
                 └─ Restore CR  → S3 버킷에서 복원
```

---

## 백엔드별 S3 변수

`setup.sh` 실행 시 MinIO/ODF 자동 감지 후 `env.conf`에 저장됩니다.
ODF 백엔드는 버킷명과 자격증명을 OBC(ObjectBucketClaim)에서 추가로 취득합니다.

| 변수 | MinIO | ODF (NooBaa MCG) |
|------|-------|-----------------|
| `S3_ENDPOINT` | `MINIO_ENDPOINT` (env.conf) | `ODF_S3_ENDPOINT` (env.conf) |
| `S3_BUCKET` | `MINIO_BUCKET` (env.conf) | OBC ConfigMap `BUCKET_NAME` |
| `S3_ACCESS_KEY` | `MINIO_ACCESS_KEY` (env.conf) | OBC Secret `AWS_ACCESS_KEY_ID` |
| `S3_SECRET_KEY` | `MINIO_SECRET_KEY` (env.conf) | OBC Secret `AWS_SECRET_ACCESS_KEY` |
| `S3_REGION` | `minio` (고정) | `ODF_S3_REGION` (env.conf, 기본: `localstorage`) |

---

## ObjectBucketClaim (ODF 백엔드 전용)

`12-oadp.sh`가 ODF 백엔드 감지 시 자동으로 OBC를 생성합니다.
OBC가 Bound 되면 버킷명과 per-bucket 자격증명을 읽어 DPA에 등록합니다.

```bash
# OBC 상태 확인
oc get obc obc-backups -n openshift-adp

# OBC ConfigMap 에서 버킷명 확인
oc get cm obc-backups -n openshift-adp -o jsonpath='{.data.BUCKET_NAME}'

# OBC Secret 에서 자격증명 확인
oc get secret obc-backups -n openshift-adp -o go-template='{{.data.AWS_ACCESS_KEY_ID | base64decode}}'
```

수동으로 생성할 경우:

```bash
# NooBaa StorageClass 확인
oc get storageclass | grep noobaa

oc apply -f - <<EOF
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata:
  name: obc-backups
  namespace: openshift-adp
spec:
  generateBucketName: backups
  storageClassName: openshift-storage.noobaa.io
EOF
```

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
# BSL 이름 확인 (OADP가 DPA 이름 기반으로 자동 생성, 예: poc-dpa-1)
BSL=$(oc get backupstoragelocation -n openshift-adp -o jsonpath='{.items[0].metadata.name}')

# 백업 대상 네임스페이스의 VM 백업
oc apply -f - <<EOF
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: poc-vm-backup
  namespace: openshift-adp
spec:
  includedNamespaces:
    - <백업할 VM 네임스페이스>
  storageLocation: ${BSL}
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

# OBC 상태 확인 (ODF 백엔드)
oc get obc obc-backups -n openshift-adp
oc describe obc obc-backups -n openshift-adp
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

# OBC 삭제 (ODF 백엔드)
oc delete obc obc-backups -n openshift-adp
```
