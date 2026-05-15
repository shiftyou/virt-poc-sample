# 21-storage-migration: VM Storage Migration (OpenShift Virtualization built-in)

## Overview

This lab demonstrates how to migrate a VM's disk from one StorageClass to another within the same
OpenShift 4.20 cluster using the **built-in storage migration feature of OpenShift Virtualization**.

No object storage (S3) is required. CDI (Containerized Data Importer) handles the data copy directly.

```
[Same Cluster]

poc-storage namespace
  VM (running)
   └── rootdisk PVC  ──── StorageClass A (e.g. standard / NFS)
                │
                │  OCP Virt storage migration
                │  (updateVolumesStrategy: migration)
                │  CDI clones PVC to new StorageClass
                ▼
   └── rootdisk PVC  ──── StorageClass B (e.g. ocs-storagecluster-ceph-rbd)
  VM (still running — live migration during cutover)
```

Storage migration flow:
1. **New DataVolume creation** — CDI clones source PVC data to target StorageClass
2. **Live migration cutover** — VM live-migrates from old PVC to new PVC
3. **Cleanup** — old PVC removed automatically

> Available from OpenShift Virtualization 4.16+

---

## Prerequisites

- OpenShift Virtualization Operator installed (`00-operator/kubevirt-hyperconverged-operator.md`)
- At least **two StorageClasses** available in the cluster
- Live migration requires the `ReadWriteManyAccessModes` feature or `LiveMigratable` condition
  - For RWO-only StorageClass: VM must support `BlockVolume` or `LiveMigratable` state
- `setup.sh` execution completed
- `21-storage-migration.sh` execution completed

---

## Architecture

```
openshift-cnv namespace
  HyperConverged / virt-controller
    └── detects updateVolumesStrategy: migration
         └── triggers volume hot-swap via live migration

CDI (openshift-cnv)
  └── DataVolume (target SC)
       └── clone source PVC → new PVC (target StorageClass)

virt-controller
  └── VirtualMachineInstanceMigration
       └── VM live-migrates to node that can attach new PVC
            └── old PVC detached → new PVC attached → migration complete
```

---

## Step 1: Verify Available StorageClasses

```bash
# Check available StorageClasses
oc get storageclass
# NAME                                    PROVISIONER                             RECLAIMPOLICY
# ocs-storagecluster-ceph-rbd (default)   openshift-storage.rbd.csi.ceph.com      Delete
# ocs-storagecluster-cephfs               openshift-storage.cephfs.csi.ceph.com   Delete
# standard                                kubernetes.io/no-provisioner             Delete

# Check which StorageClass supports live migration (RWX or Block mode)
oc get storageclass -o json | jq -r '.items[] | "\(.metadata.name): \(.volumeBindingMode)"'
```

---

## Step 2: Create Source VM

Create a VM with a PVC on the source StorageClass.

```bash
# Create namespace
oc new-project poc-storage

# Confirm source StorageClass (use current default)
SRC_SC=$(oc get storageclass \
  -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}')
echo "Source StorageClass: ${SRC_SC}"

# Create VM from poc template
oc process -n openshift poc -p NAME="poc-storage-vm" | \
  sed 's/  running: false/  runStrategy: Always/' | \
  oc apply -n poc-storage -f -

# Confirm VM is Running
oc get vm poc-storage-vm -n poc-storage
oc get vmi poc-storage-vm -n poc-storage
```

Verify source PVC StorageClass:
```bash
oc get pvc -n poc-storage
# NAME              STATUS   VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   AGE
# poc-storage-vm    Bound    ...      30Gi       RWO            <SRC_SC>       ...
```

---

## Step 3: Migrate Storage (CLI)

### 3-1. Check target StorageClass

```bash
# List StorageClasses other than source
oc get storageclass --no-headers -o custom-columns=NAME:.metadata.name | grep -v "${SRC_SC}"

# Set target StorageClass
DST_SC="<target StorageClass name>"
echo "Source: ${SRC_SC} → Destination: ${DST_SC}"
```

### 3-2. Create new DataVolume (target StorageClass)

Create a DataVolume that clones from the existing PVC.

```bash
# Get source PVC size
PVC_SIZE=$(oc get pvc poc-storage-vm -n poc-storage \
  -o jsonpath='{.spec.resources.requests.storage}')
echo "PVC size: ${PVC_SIZE}"

# Create clone DataVolume with target StorageClass
oc apply -f - <<EOF
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: poc-storage-vm-migrated
  namespace: poc-storage
spec:
  storage:
    storageClassName: ${DST_SC}
    resources:
      requests:
        storage: ${PVC_SIZE}
  source:
    pvc:
      namespace: poc-storage
      name: poc-storage-vm
EOF

# Monitor clone progress
watch oc get datavolume poc-storage-vm-migrated -n poc-storage
# PHASE should change: CloneScheduled → CloneInProgress → Succeeded
```

### 3-3. Trigger storage migration

Patch the VM to point to the new DataVolume and trigger live migration cutover.

```bash
# Stop VM temporarily for volume hot-swap (or use live migration if RWX supported)
# For RWO storage: brief stop is required
oc patch vm poc-storage-vm -n poc-storage --type=merge -p '{
  "spec": {
    "runStrategy": "Halted"
  }
}'

# Wait for VM to stop
oc wait vmi poc-storage-vm -n poc-storage \
  --for=delete --timeout=2m 2>/dev/null || true

# Swap volume reference to migrated DataVolume
oc patch vm poc-storage-vm -n poc-storage --type=json -p '[
  {
    "op": "replace",
    "path": "/spec/template/spec/volumes/0/dataVolume/name",
    "value": "poc-storage-vm-migrated"
  }
]'

# Restart VM
oc patch vm poc-storage-vm -n poc-storage --type=merge -p '{
  "spec": {
    "runStrategy": "Always"
  }
}'

# Wait for VM to start
oc wait vmi poc-storage-vm -n poc-storage \
  --for=condition=Ready --timeout=5m
```

> **RWX StorageClass (live migration):** If both source and destination StorageClasses support RWX,
> use `updateVolumesStrategy: migration` for zero-downtime migration. See [Section 3-4](#3-4-live-migration-zero-downtime-rwx-only).

### 3-4. Live migration (zero-downtime, RWX only)

If the target StorageClass supports `ReadWriteMany`, the VM can stay running during cutover.

```bash
# Patch VM: point to new DataVolume + set updateVolumesStrategy: migration
oc patch vm poc-storage-vm -n poc-storage --type=merge -p "{
  \"spec\": {
    \"updateVolumesStrategy\": \"migration\",
    \"template\": {
      \"spec\": {
        \"volumes\": [
          {
            \"name\": \"rootdisk\",
            \"dataVolume\": {
              \"name\": \"poc-storage-vm-migrated\"
            }
          }
        ]
      }
    }
  }
}"

# Monitor VirtualMachineInstanceMigration (auto-created by virt-controller)
watch oc get vmim -n poc-storage
# NAME                              PHASE       VMI
# kubevirt-storage-migration-xxxx   Succeeded   poc-storage-vm
```

---

## Step 4: Migrate Storage (Console UI)

> Available from OpenShift Virtualization 4.16+

1. Navigate to **Virtualization → VirtualMachines**
2. Select **poc-storage-vm**
3. Click the **Disks** tab
4. Click the **⋮** menu next to the disk → **Migrate storage**
5. Select **Target StorageClass** from the dropdown
6. Click **Migrate**
7. Monitor progress in the **Events** tab or via CLI:
   ```bash
   oc get datavolume -n poc-storage
   oc get vmim -n poc-storage
   ```

---

## Step 5: Verify Migration Results

```bash
# Confirm new PVC StorageClass
oc get pvc -n poc-storage
# NAME                       STATUS   VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   AGE
# poc-storage-vm-migrated    Bound    ...      30Gi       RWO            <DST_SC>       ...

# Confirm VM is using migrated disk
oc get vm poc-storage-vm -n poc-storage \
  -o jsonpath='{.spec.template.spec.volumes[0].dataVolume.name}'
# poc-storage-vm-migrated

# Confirm VM is running
oc get vmi poc-storage-vm -n poc-storage
# NAME              AGE   PHASE     IP   NODENAME   READY
# poc-storage-vm    ...   Running   ...  ...        True

# Delete old PVC (after confirming migration success)
oc delete pvc poc-storage-vm -n poc-storage
```

---

## Monitoring Migration Progress

```bash
# DataVolume clone progress
oc get datavolume -n poc-storage -w

# CDI controller logs (clone operation)
oc logs -n openshift-cnv -l app=cdi-controller --tail=50

# VirtualMachineInstanceMigration status (live migration method)
oc get vmim -n poc-storage
oc describe vmim -n poc-storage

# virt-controller logs
oc logs -n openshift-cnv -l kubevirt.io=virt-controller --tail=50
```

---

## Troubleshooting

### DataVolume Clone Stuck

```bash
# Check DataVolume status and events
oc describe datavolume poc-storage-vm-migrated -n poc-storage

# Check CDI importer Pod
oc get pods -n poc-storage | grep importer
oc logs -n poc-storage <importer-pod-name>

# Check source PVC is not in use by another process
oc describe pvc poc-storage-vm -n poc-storage
```

### VM Does Not Start After Volume Swap

```bash
# Check VM events
oc describe vm poc-storage-vm -n poc-storage | tail -20

# Revert to original volume if needed
oc patch vm poc-storage-vm -n poc-storage --type=json -p '[
  {
    "op": "replace",
    "path": "/spec/template/spec/volumes/0/dataVolume/name",
    "value": "poc-storage-vm"
  }
]'
oc patch vm poc-storage-vm -n poc-storage --type=merge -p '{"spec":{"runStrategy":"Always"}}'
```

### Live Migration Not Supported

```bash
# Check VMI LiveMigratable condition
oc get vmi poc-storage-vm -n poc-storage \
  -o jsonpath='{.status.conditions[?(@.type=="LiveMigratable")].status}'

# Check non-migratable reason
oc get vmi poc-storage-vm -n poc-storage \
  -o jsonpath='{.status.conditions[?(@.type=="LiveMigratable")].message}'
```

---

## Rollback

```bash
# If migration is not yet cut over — delete the new DataVolume and clear updateVolumesStrategy
oc patch vm poc-storage-vm -n poc-storage --type=json -p '[
  {"op": "remove", "path": "/spec/updateVolumesStrategy"}
]'
oc delete datavolume poc-storage-vm-migrated -n poc-storage --ignore-not-found
```

---

## References

- [OpenShift Virtualization: Migrating virtual machine disks to a different storage class](https://docs.openshift.com/container-platform/4.20/virt/storage/virt-migrating-vm-disk-to-different-storage-class.html)
- [CDI DataVolume cloning](https://docs.openshift.com/container-platform/4.20/virt/storage/virt-cloning-vm-disk-into-new-datavolume.html)
- [VM live migration](https://docs.openshift.com/container-platform/4.20/virt/live_migration/virt-live-migration.html)
