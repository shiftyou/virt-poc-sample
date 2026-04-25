# OADP (OpenShift API for Data Protection) Lab

This is a lab for backing up and restoring VMs using OADP.

```
VM (backup target namespace)
  │  Create Backup CR
  ▼
OADP (Velero) — openshift-adp namespace
  └─ VM snapshot + PVC data
       │  Store in S3 (MinIO or ODF MCG)
       ▼
  Backup complete

Restore:
  Create Restore CR → OADP → Recreate VM
```

---

## Prerequisites

- OADP Operator installed (`00-operator/oadp-operator.md` for reference) — **installed in `openshift-adp` namespace**
- S3 backend: Deploy **MinIO community version** or install **ODF Operator** (see MinIO installation guide below)
- `setup.sh` execution completed (auto-detects MinIO/ODF and saves to `env.conf`)
- `13-oadp.sh` execution completed

---

## MinIO Community Version Installation

A method to deploy MinIO as a simple Deployment without an Operator.
Use this when you want to quickly set up an S3 backend without ODF.

### 1. Namespace and SCC Setup

```bash
oc new-project minio

# MinIO container needs write access to /data directory with arbitrary UID — grant anyuid
oc adm policy add-scc-to-user anyuid -z default -n minio
```

### 2. Deploy Resources

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

### 3. Verify Startup

```bash
oc get pods -n minio
# NAME                     READY   STATUS    RESTARTS   AGE
# minio-xxxxxxxxx-xxxxx    1/1     Running   0          1m

oc get route -n minio
# NAME            HOST/PORT                              ...
# minio-api       minio-api-minio.apps.cluster.com       ...
# minio-console   minio-console-minio.apps.cluster.com   ...
```

### 4. Create Bucket

#### Method A — MinIO Console (Web UI)

1. Access `https://minio-console-minio.apps.<cluster-domain>`
2. Login with ID: `minioadmin` / PW: `minioadmin`
3. **Buckets → Create Bucket** → Name: `velero-backups`

#### Method B — mc client (CLI)

```bash
# Install mc (on bastion or locally)
curl -sO https://dl.min.io/client/mc/release/linux-amd64/mc
chmod +x mc && mv mc /usr/local/bin/

# Check MinIO API Route address
MINIO_API=$(oc get route minio-api -n minio -o jsonpath='{.status.ingress[0].host}')

# Register alias
mc alias set poc https://${MINIO_API} minioadmin minioadmin --insecure

# Create bucket
mc mb poc/velero-backups --insecure

# Verify
mc ls poc --insecure
```

### 5. Manual env.conf Settings

If `setup.sh` fails to detect MinIO, add the following values directly to `env.conf`.

```bash
MINIO_INSTALLED=true
MINIO_ENDPOINT=https://minio-api-minio.apps.<cluster-domain>
MINIO_ACCESS_KEY=minioadmin
MINIO_SECRET_KEY=minioadmin
MINIO_BUCKET=velero-backups
```

After that, run `13-oadp.sh` to configure DPA with these values.

---

## Configuration Overview

| Item | Value |
|------|-----|
| OADP / DPA namespace | `openshift-adp` (or `OADP_NS` detected value if not found) |
| cloud-credentials Secret | `openshift-adp` |
| BackupStorageLocation | `openshift-adp` |
| Backup / Restore | `openshift-adp` |
| S3 backend | MinIO preferred, ODF MCG if not available |

```
OBC obc-backups (openshift-adp) — auto-created when ODF backend is used
  └─ cloud-credentials Secret (openshift-adp)
       └─ DataProtectionApplication poc-dpa (openshift-adp)
            └─ BackupStorageLocation default
                 │
                 ├─ Backup CR   → Store in S3 bucket
                 └─ Restore CR  → Restore from S3 bucket
```

---

## S3 Variables by Backend

When `setup.sh` runs, it auto-detects MinIO/ODF and saves to `env.conf`.
For ODF backend, bucket name and credentials are additionally obtained from OBC (ObjectBucketClaim).

| Variable | MinIO | ODF (NooBaa MCG) |
|------|-------|-----------------|
| `S3_ENDPOINT` | `MINIO_ENDPOINT` (env.conf) | `ODF_S3_ENDPOINT` (env.conf) |
| `S3_BUCKET` | `MINIO_BUCKET` (env.conf) | OBC ConfigMap `BUCKET_NAME` |
| `S3_ACCESS_KEY` | `MINIO_ACCESS_KEY` (env.conf) | OBC Secret `AWS_ACCESS_KEY_ID` |
| `S3_SECRET_KEY` | `MINIO_SECRET_KEY` (env.conf) | OBC Secret `AWS_SECRET_ACCESS_KEY` |
| `S3_REGION` | `minio` (fixed) | `ODF_S3_REGION` (env.conf, default: `localstorage`) |

---

## ObjectBucketClaim (ODF backend only)

`13-oadp.sh` automatically creates an OBC when ODF backend is detected.
Once the OBC is Bound, it reads the bucket name and per-bucket credentials to register with DPA.

```bash
# Check OBC status
oc get obc obc-backups -n openshift-adp

# Get bucket name from OBC ConfigMap
oc get cm obc-backups -n openshift-adp -o jsonpath='{.data.BUCKET_NAME}'

# Get credentials from OBC Secret
oc get secret obc-backups -n openshift-adp -o go-template='{{.data.AWS_ACCESS_KEY_ID | base64decode}}'
```

To create manually:

```bash
# Check NooBaa StorageClass
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

## DataProtectionApplication Settings

`13-oadp.sh` automatically creates and applies this. Refer to the following for manual application.

```bash
# 1. Create cloud-credentials Secret (openshift-adp)
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

# 2. Create DataProtectionApplication
oc apply -f - <<EOF
apiVersion: oadp.openshift.io/v1alpha1
kind: DataProtectionApplication
metadata:
  name: poc-dpa
  namespace: openshift-adp
spec:
  configuration:
    nodeAgent:
      enable: true
      uploaderType: restic
    velero:
      defaultPlugins:
        - aws
        - openshift
        - kubevirt
        - csi
      disableFsBackup: false
  logFormat: text
  backupLocations:
    - velero:
        provider: aws
        default: true
        objectStorage:
          bucket: ${S3_BUCKET}
          prefix: oadp
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

## VolumeSnapshotClass (CSI snapshot)

`13-oadp.sh` auto-detects the cluster's CSI driver and generates `volumesnapshotclass.yaml`.
Apply directly if using CSI snapshots.

```bash
# Review generated file and apply
oc apply -f volumesnapshotclass.yaml

# Check list of CSI drivers
oc get csidrivers
```

---

## VM Backup

```bash
# Get BSL name (OADP auto-creates based on DPA name, e.g.: poc-dpa-1)
BSL=$(oc get backupstoragelocation -n openshift-adp -o jsonpath='{.items[0].metadata.name}')

# Backup VMs in the target namespace
oc apply -f - <<EOF
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: poc-vm-backup
  namespace: openshift-adp
spec:
  includedNamespaces:
    - <VM namespace to backup>
  storageLocation: ${BSL}
  ttl: 720h0m0s
  snapshotVolumes: true
EOF

# Check backup status
oc get backup -n openshift-adp

# Check backup details
oc describe backup poc-vm-backup -n openshift-adp
```

---

## VM Restore

```bash
# Restore from backup
oc apply -f - <<EOF
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: poc-vm-restore
  namespace: openshift-adp
spec:
  backupName: poc-vm-backup
  includedNamespaces:
    - <VM namespace to restore>
  restorePVs: true
EOF

# Check restore status
oc get restore -n openshift-adp

# Check restored VMs (specify the restore target namespace)
oc get vm -n <VM namespace to restore>
```

---

## BackupStorageLocation Verification

```bash
# BackupStorageLocation status (must be Available)
oc get backupstoragelocation -n openshift-adp

# Check details
oc describe backupstoragelocation -n openshift-adp
```

---

## Schedule — Periodic Backup

```bash
# Automatic backup every day at 2 AM
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
      - <VM namespace to backup>
    storageLocation: default
    ttl: 168h0m0s
    snapshotVolumes: true
EOF

# Check Schedule
oc get schedule -n openshift-adp
```

---

## Troubleshooting

```bash
# Velero Pod logs
oc logs -n openshift-adp -l app.kubernetes.io/name=velero --tail=50

# NodeAgent logs (PVC backup/restore)
oc logs -n openshift-adp daemonset/node-agent --tail=30

# BackupStorageLocation details
oc describe backupstoragelocation -n openshift-adp

# Check DPA status
oc get dpa poc-dpa -n openshift-adp -o yaml

# Check OBC status (ODF backend)
oc get obc obc-backups -n openshift-adp
oc describe obc obc-backups -n openshift-adp
```

---

## Rollback

```bash
# Delete Schedule
oc delete schedule poc-daily-backup -n openshift-adp

# Delete DataProtectionApplication
oc delete dpa poc-dpa -n openshift-adp

# Delete cloud-credentials Secret
oc delete secret cloud-credentials -n openshift-adp

# Delete OBC (ODF backend)
oc delete obc obc-backups -n openshift-adp
```
