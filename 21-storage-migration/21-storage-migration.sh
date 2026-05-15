#!/bin/bash
# =============================================================================
# 21-storage-migration.sh
#
# VM storage migration lab — OpenShift Virtualization built-in feature
#   1. Pre-flight check (OpenShift Virtualization + StorageClass selection)
#   2. Create poc-storage namespace
#   3. Create source VM (poc template, source StorageClass)
#   4. Create target DataVolume (CDI clone to destination StorageClass)
#   5. Execute storage migration (RWO: stop/swap/start, RWX: live migration)
#   6. Verify results
#   7. Clean up old PVC
#
# Requirements:
#   - OpenShift Virtualization Operator must be installed
#   - At least two StorageClasses must be available
#   - poc template must exist in openshift namespace (run 01-template first)
#
# Usage: ./21-storage-migration.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

VM_NS="poc-storage"
VM_NAME="poc-storage-vm"
SRC_DV_NAME="${VM_NAME}"
DST_DV_NAME="${VM_NAME}-migrated"

SRC_SC=""
DST_SC=""
MIGRATE_METHOD=""  # "live" or "restart"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

print_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
print_ok()    { echo -e "${GREEN}[ OK ]${NC} $1"; }
print_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERR ]${NC} $1"; }
print_step()  { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }

# =============================================================================
# Pre-flight
# =============================================================================
preflight() {
    print_step "Pre-flight check"

    if ! oc whoami &>/dev/null; then
        print_error "Not logged in to OpenShift."
        exit 1
    fi
    print_ok "Cluster connection: $(oc whoami) @ $(oc whoami --show-server)"

    if [ "${VIRT_INSTALLED:-false}" != "true" ]; then
        print_warn "OpenShift Virtualization Operator not installed → skipping."
        print_warn "  Installation guide: 00-operator/kubevirt-hyperconverged-operator.md"
        exit 77
    fi
    print_ok "OpenShift Virtualization confirmed"

    # Check poc template
    if ! oc get template poc -n openshift &>/dev/null; then
        print_warn "poc template not found in openshift namespace."
        print_warn "  Please run 01-template first."
        exit 77
    fi
    print_ok "poc template confirmed"

    # List available StorageClasses
    echo ""
    print_info "Available StorageClasses:"
    oc get storageclass --no-headers \
        -o custom-columns=NAME:.metadata.name,PROVISIONER:.provisioner,DEFAULT:.metadata.annotations."storageclass\.kubernetes\.io/is-default-class" \
        2>/dev/null || true
    echo ""

    # Source StorageClass — default
    local default_sc
    default_sc=$(oc get storageclass \
        -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' \
        2>/dev/null | awk '{print $1}')
    SRC_SC="${STORAGE_MIGRATION_SRC_SC:-${default_sc}}"
    read -r -p "  Source StorageClass      [${SRC_SC}]: " _input
    [ -n "$_input" ] && SRC_SC="$_input"

    # Destination StorageClass — first one that differs from source
    local other_sc
    other_sc=$(oc get storageclass --no-headers -o custom-columns=NAME:.metadata.name \
        2>/dev/null | grep -v "^${SRC_SC}$" | head -1 || true)
    DST_SC="${STORAGE_MIGRATION_DST_SC:-${other_sc}}"
    read -r -p "  Destination StorageClass [${DST_SC}]: " _input
    [ -n "$_input" ] && DST_SC="$_input"

    if [ -z "${SRC_SC}" ] || [ -z "${DST_SC}" ]; then
        print_error "StorageClass is empty — need at least two StorageClasses."
        exit 1
    fi
    if [ "${SRC_SC}" = "${DST_SC}" ]; then
        print_warn "Source and destination StorageClasses are the same: ${SRC_SC}"
        print_warn "Migration will proceed but StorageClass will not change."
    fi
    print_ok "StorageClass: ${SRC_SC} → ${DST_SC}"

    # Check if destination SC supports RWX (live migration possible)
    local dst_sc_mode
    dst_sc_mode=$(oc get storageclass "${DST_SC}" \
        -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' 2>/dev/null || true)

    # Check VMI live-migratability at runtime — decide method after VM is created
    MIGRATE_METHOD="restart"  # default; updated in step_migrate after VM is ready
    print_info "Migration method will be determined after VM is ready (live if RWX supported)."
}

# =============================================================================
# Step 1: Create namespace
# =============================================================================
step_namespace() {
    print_step "1/5  Create namespace (${VM_NS})"

    if oc get namespace "$VM_NS" &>/dev/null; then
        print_ok "Namespace $VM_NS already exists — skipping"
    else
        oc new-project "$VM_NS" > /dev/null
        print_ok "Namespace $VM_NS created"
    fi
}

# =============================================================================
# Step 2: Create source VM
# =============================================================================
step_vm() {
    print_step "2/5  Create source VM (ns: ${VM_NS}, StorageClass: ${SRC_SC})"

    if oc get vm "$VM_NAME" -n "$VM_NS" &>/dev/null; then
        print_ok "VM $VM_NAME already exists — skipping"
    else
        local vm_yaml="${SCRIPT_DIR}/poc-storage-vm.yaml"
        oc process -n openshift poc -p NAME="$VM_NAME" | \
            jq --arg sc "${SRC_SC}" '
              .items[0].spec.runStrategy = "Always" |
              .items[0].spec.dataVolumeTemplates[0].spec.storage.storageClassName = $sc
            ' > "${vm_yaml}"
        echo "Generated file: poc-storage-vm.yaml"
        oc apply -f "${vm_yaml}"
        print_ok "VM $VM_NAME created (StorageClass: ${SRC_SC})"
    fi

    # Wait for VM to be Running
    print_info "Waiting for VM to start..."
    local i=0
    while [ $i -lt 24 ]; do
        local phase
        phase=$(oc get vmi "$VM_NAME" -n "$VM_NS" \
            -o jsonpath='{.status.phase}' 2>/dev/null || true)
        if [ "$phase" = "Running" ]; then
            print_ok "VM $VM_NAME is Running"
            break
        fi
        printf "  [%d/24] VMI phase: %s\r" "$((i+1))" "${phase:-Pending}"
        sleep 10
        i=$((i+1))
    done
    echo ""

    if [ $i -eq 24 ]; then
        print_warn "VM start timed out. Continuing — check: oc get vmi ${VM_NAME} -n ${VM_NS}"
    fi

    # Show current PVC
    echo ""
    print_info "Current PVC:"
    oc get pvc -n "$VM_NS" 2>/dev/null || true
}

# =============================================================================
# Step 3: Create target DataVolume (CDI clone)
# =============================================================================
step_clone() {
    print_step "3/5  Clone PVC to destination StorageClass (CDI)"

    if oc get datavolume "$DST_DV_NAME" -n "$VM_NS" &>/dev/null; then
        print_ok "DataVolume $DST_DV_NAME already exists — skipping"
    else
        # Get source PVC capacity
        local pvc_size
        pvc_size=$(oc get pvc "$SRC_DV_NAME" -n "$VM_NS" \
            -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null || echo "30Gi")
        print_info "Source PVC size: ${pvc_size}"

        cat > "${SCRIPT_DIR}/poc-storage-vm-migrated-dv.yaml" <<EOF
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: ${DST_DV_NAME}
  namespace: ${VM_NS}
spec:
  storage:
    storageClassName: ${DST_SC}
    resources:
      requests:
        storage: ${pvc_size}
  source:
    pvc:
      namespace: ${VM_NS}
      name: ${SRC_DV_NAME}
EOF
        echo "Generated file: poc-storage-vm-migrated-dv.yaml"
        oc apply -f "${SCRIPT_DIR}/poc-storage-vm-migrated-dv.yaml"
        print_ok "DataVolume $DST_DV_NAME created (cloning from ${SRC_DV_NAME} → StorageClass: ${DST_SC})"
    fi

    # Wait for clone to complete
    print_info "Waiting for CDI clone to complete (this may take several minutes)..."
    local i=0
    while [ $i -lt 60 ]; do
        local phase progress
        phase=$(oc get datavolume "$DST_DV_NAME" -n "$VM_NS" \
            -o jsonpath='{.status.phase}' 2>/dev/null || true)
        progress=$(oc get datavolume "$DST_DV_NAME" -n "$VM_NS" \
            -o jsonpath='{.status.progress}' 2>/dev/null || true)
        if [ "$phase" = "Succeeded" ]; then
            print_ok "CDI clone completed: DataVolume $DST_DV_NAME is Succeeded"
            break
        fi
        if [ "$phase" = "Failed" ]; then
            print_error "CDI clone failed."
            print_error "  oc describe datavolume ${DST_DV_NAME} -n ${VM_NS}"
            exit 1
        fi
        printf "  [%d/60] Phase: %-20s Progress: %s\r" "$((i+1))" "${phase:-Pending}" "${progress:--}"
        sleep 10
        i=$((i+1))
    done
    echo ""

    if [ $i -eq 60 ]; then
        print_warn "CDI clone timed out."
        print_warn "  oc get datavolume ${DST_DV_NAME} -n ${VM_NS}"
        print_warn "  oc describe datavolume ${DST_DV_NAME} -n ${VM_NS}"
    fi
}

# =============================================================================
# Step 4: Execute storage migration
# =============================================================================
step_migrate() {
    print_step "4/5  Storage migration"

    # Determine migration method: live (RWX) or restart (RWO)
    local live_migratable
    live_migratable=$(oc get vmi "$VM_NAME" -n "$VM_NS" \
        -o jsonpath='{.status.conditions[?(@.type=="LiveMigratable")].status}' 2>/dev/null || true)

    if [ "$live_migratable" = "True" ]; then
        MIGRATE_METHOD="live"
        print_info "VMI supports live migration → using live migration method (zero-downtime)"
    else
        MIGRATE_METHOD="restart"
        local reason
        reason=$(oc get vmi "$VM_NAME" -n "$VM_NS" \
            -o jsonpath='{.status.conditions[?(@.type=="LiveMigratable")].message}' 2>/dev/null || true)
        print_info "VMI live migration not available (${reason:-reason unknown}) → using restart method"
        print_warn "VM will be briefly stopped during volume swap."
    fi

    echo ""
    read -r -p "  Proceed with migration? (Y/n): " _confirm
    if [[ "${_confirm:-}" =~ ^[Nn]$ ]]; then
        print_info "Migration skipped."
        return
    fi

    if [ "$MIGRATE_METHOD" = "live" ]; then
        _migrate_live
    else
        _migrate_restart
    fi
}

_migrate_live() {
    print_info "Method: Live migration (updateVolumesStrategy)"

    # Get current volume list and patch
    local vol_json
    vol_json=$(oc get vm "$VM_NAME" -n "$VM_NS" \
        -o jsonpath='{.spec.template.spec.volumes}' 2>/dev/null)
    local vol_name
    vol_name=$(oc get vm "$VM_NAME" -n "$VM_NS" \
        -o jsonpath='{.spec.template.spec.volumes[0].name}' 2>/dev/null || echo "rootdisk")

    oc patch vm "$VM_NAME" -n "$VM_NS" --type=merge -p "{
      \"spec\": {
        \"updateVolumesStrategy\": \"migration\",
        \"template\": {
          \"spec\": {
            \"volumes\": [
              {
                \"name\": \"${vol_name}\",
                \"dataVolume\": {
                  \"name\": \"${DST_DV_NAME}\"
                }
              }
            ]
          }
        }
      }
    }"
    print_ok "VM patched with updateVolumesStrategy: migration"

    # Wait for VirtualMachineInstanceMigration
    print_info "Waiting for live migration to complete..."
    local i=0
    while [ $i -lt 36 ]; do
        local vmim_phase
        vmim_phase=$(oc get vmim -n "$VM_NS" --no-headers \
            -o custom-columns=PHASE:.status.phase 2>/dev/null | head -1 || true)
        if [ "$vmim_phase" = "Succeeded" ]; then
            print_ok "Live migration completed: Succeeded"
            break
        fi
        if [ "$vmim_phase" = "Failed" ]; then
            print_error "Live migration failed."
            print_error "  oc describe vmim -n ${VM_NS}"
            exit 1
        fi
        printf "  [%d/36] VMIM phase: %s\r" "$((i+1))" "${vmim_phase:-Pending}"
        sleep 10
        i=$((i+1))
    done
    echo ""

    if [ $i -eq 36 ]; then
        print_warn "Live migration timed out — check: oc get vmim -n ${VM_NS}"
    fi
}

_migrate_restart() {
    print_info "Method: Stop VM → swap volume → restart VM"

    # Stop VM
    print_info "Stopping VM $VM_NAME..."
    oc patch vm "$VM_NAME" -n "$VM_NS" --type=merge -p '{"spec":{"runStrategy":"Halted"}}'

    local i=0
    while [ $i -lt 18 ]; do
        local vmi_exists
        vmi_exists=$(oc get vmi "$VM_NAME" -n "$VM_NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')
        if [ "$vmi_exists" = "0" ]; then
            print_ok "VM stopped"
            break
        fi
        printf "  [%d/18] Waiting for VM to stop...\r" "$((i+1))"
        sleep 5
        i=$((i+1))
    done
    echo ""

    # Swap volume reference
    local vol_name
    vol_name=$(oc get vm "$VM_NAME" -n "$VM_NS" \
        -o jsonpath='{.spec.template.spec.volumes[0].name}' 2>/dev/null || echo "rootdisk")

    oc patch vm "$VM_NAME" -n "$VM_NS" --type=json -p "[
      {
        \"op\": \"replace\",
        \"path\": \"/spec/template/spec/volumes/0/dataVolume/name\",
        \"value\": \"${DST_DV_NAME}\"
      }
    ]"
    print_ok "Volume reference updated: ${SRC_DV_NAME} → ${DST_DV_NAME}"

    # Restart VM
    oc patch vm "$VM_NAME" -n "$VM_NS" --type=merge -p '{"spec":{"runStrategy":"Always"}}'
    print_info "VM restarting..."

    local i=0
    while [ $i -lt 24 ]; do
        local phase
        phase=$(oc get vmi "$VM_NAME" -n "$VM_NS" \
            -o jsonpath='{.status.phase}' 2>/dev/null || true)
        if [ "$phase" = "Running" ]; then
            print_ok "VM $VM_NAME is Running"
            break
        fi
        printf "  [%d/24] VMI phase: %s\r" "$((i+1))" "${phase:-Pending}"
        sleep 10
        i=$((i+1))
    done
    echo ""

    if [ $i -eq 24 ]; then
        print_warn "VM start timed out — check: oc get vmi ${VM_NAME} -n ${VM_NS}"
    fi
}

# =============================================================================
# Step 5: Verify and cleanup
# =============================================================================
step_verify() {
    print_step "5/5  Verify migration results"

    echo ""
    print_info "VM status:"
    oc get vm "$VM_NAME" -n "$VM_NS" 2>/dev/null || true

    echo ""
    print_info "VMI status:"
    oc get vmi "$VM_NAME" -n "$VM_NS" 2>/dev/null || true

    echo ""
    print_info "PVC list:"
    oc get pvc -n "$VM_NS" 2>/dev/null || true

    echo ""
    local current_vol
    current_vol=$(oc get vm "$VM_NAME" -n "$VM_NS" \
        -o jsonpath='{.spec.template.spec.volumes[0].dataVolume.name}' 2>/dev/null || true)
    print_info "VM currently using DataVolume: ${current_vol}"

    local dst_sc_actual
    dst_sc_actual=$(oc get pvc "$DST_DV_NAME" -n "$VM_NS" \
        -o jsonpath='{.spec.storageClassName}' 2>/dev/null || true)

    if [ -n "$dst_sc_actual" ] && [ "$dst_sc_actual" = "$DST_SC" ]; then
        print_ok "StorageClass migration confirmed: ${SRC_SC} → ${DST_SC}"
    else
        print_warn "Destination PVC StorageClass: ${dst_sc_actual:-unknown} (expected: ${DST_SC})"
    fi

    if [ "$current_vol" = "$DST_DV_NAME" ]; then
        print_ok "VM is using the migrated DataVolume: $DST_DV_NAME"
        echo ""
        print_info "Old PVC (${SRC_DV_NAME}) is no longer in use."
        read -r -p "  Delete old PVC ${SRC_DV_NAME}? (y/N): " _confirm
        if [[ "${_confirm:-}" =~ ^[Yy]$ ]]; then
            oc delete pvc "$SRC_DV_NAME" -n "$VM_NS" --ignore-not-found 2>/dev/null && \
                print_ok "Old PVC ${SRC_DV_NAME} deleted" || \
                print_warn "Old PVC deletion failed — check: oc get pvc -n ${VM_NS}"
        else
            print_info "Old PVC retained. Delete manually when ready:"
            echo -e "    ${CYAN}oc delete pvc ${SRC_DV_NAME} -n ${VM_NS}${NC}"
        fi
    else
        print_warn "VM does not appear to be using migrated DataVolume yet."
        print_warn "  current: ${current_vol}, expected: ${DST_DV_NAME}"
    fi
}

print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  Done! Storage migration lab completed.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  Migration method    : ${MIGRATE_METHOD}"
    echo -e "  StorageClass        : ${SRC_SC} → ${DST_SC}"
    echo -e "  Namespace           : ${VM_NS}"
    echo ""
    echo -e "  Check VM status:"
    echo -e "    ${CYAN}oc get vm,vmi -n ${VM_NS}${NC}"
    echo ""
    echo -e "  Check PVC:"
    echo -e "    ${CYAN}oc get pvc -n ${VM_NS}${NC}"
    echo ""
    echo -e "  For details: 21-storage-migration.md"
    echo ""
}

# =============================================================================
# Cleanup
# =============================================================================
cleanup() {
    print_step "--cleanup: Delete 21-storage-migration resources"
    oc delete project "$VM_NS" --ignore-not-found 2>/dev/null || true
    print_ok "21-storage-migration resources deleted"
}

main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  VM storage migration lab (OpenShift Virtualization built-in)${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    preflight
    step_namespace
    step_vm
    step_clone
    step_migrate
    step_verify
    print_summary
}

[ "${1:-}" = "--cleanup" ] && { cleanup; exit 0; }
main
