#!/bin/bash
# =============================================================================
# virt-poc-sample environment setup script
# Collects environment variables for OpenShift Virtualization POC testing
# and generates the env.conf file.
#
# Usage: ./setup.sh
# =============================================================================

set -euo pipefail

ENV_FILE="./env.conf"
EXAMPLE_FILE="./env.conf.example"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

print_header() {
    echo ""
    echo -e "${CYAN}================================================================${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}================================================================${NC}"
    echo ""
}

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_ok() {
    echo -e "${GREEN}[OK]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Input function: prompt message, default value, variable name
ask() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"
    local is_secret="${4:-false}"

    if [ "$is_secret" = "true" ]; then
        echo -n -e "${YELLOW}  $prompt${NC} [default: ****]: "
        read -s input_val
        echo ""
    else
        echo -n -e "${YELLOW}  $prompt${NC} [default: ${default}]: "
        read input_val
    fi

    if [ -z "$input_val" ]; then
        input_val="$default"
    fi

    eval "$var_name='$input_val'"
}

# Check oc command
check_oc() {
    if ! command -v oc &> /dev/null; then
        print_warn "oc command not found. Saving configuration without cluster connection."
        return 1
    fi

    if ! oc whoami &> /dev/null; then
        print_warn "Not logged in to OpenShift cluster. Saving configuration only."
        return 1
    fi

    print_ok "OpenShift cluster connected: $(oc whoami)"
    return 0
}

# Check operator installation
check_operators() {
    print_header "Pre-check: Operator Installation Status"

    VIRT_INSTALLED=false
    MTV_INSTALLED=false
    DESCHEDULER_INSTALLED=false
    FAR_INSTALLED=false
    NMO_INSTALLED=false
    NHC_INSTALLED=false
    SNR_INSTALLED=false
    NMSTATE_INSTALLED=false
    OADP_INSTALLED=false
    GRAFANA_INSTALLED=false

    if check_oc 2>/dev/null; then
        oc get csv -A 2>/dev/null > /tmp/_poc_csv.txt || true

        grep -qi "kubevirt-hyperconverged"   /tmp/_poc_csv.txt 2>/dev/null && VIRT_INSTALLED=true
        grep -qi "mtv-operator"              /tmp/_poc_csv.txt 2>/dev/null && MTV_INSTALLED=true
        grep -qi "kube-descheduler"          /tmp/_poc_csv.txt 2>/dev/null && DESCHEDULER_INSTALLED=true
        grep -qi "fence-agents-remediation"  /tmp/_poc_csv.txt 2>/dev/null && FAR_INSTALLED=true
        grep -qi "node-maintenance"          /tmp/_poc_csv.txt 2>/dev/null && NMO_INSTALLED=true
        grep -qi "node-healthcheck"          /tmp/_poc_csv.txt 2>/dev/null && NHC_INSTALLED=true
        grep -qi "self-node-remediation"     /tmp/_poc_csv.txt 2>/dev/null && SNR_INSTALLED=true
        grep -qi "kubernetes-nmstate"        /tmp/_poc_csv.txt 2>/dev/null && NMSTATE_INSTALLED=true
        grep -qi "oadp-operator"             /tmp/_poc_csv.txt 2>/dev/null && OADP_INSTALLED=true
        grep -qi "grafana-operator"          /tmp/_poc_csv.txt 2>/dev/null && GRAFANA_INSTALLED=true
        rm -f /tmp/_poc_csv.txt
        # Check NMState CR instance separately
        NMSTATE_CR_EXISTS=false
        if [ "$NMSTATE_INSTALLED" = "true" ]; then
            oc get nmstate 2>/dev/null | grep -q "." && NMSTATE_CR_EXISTS=true || true
        fi
    else
        print_warn "Cannot check operator status: not connected to cluster."
        print_info "Operator installation guide: 00-init/README.md"
        echo ""
        return
    fi

    local ok="${GREEN}[✔]${NC}"
    local ng="${RED}[✘]${NC}"
    local wa="${YELLOW}[~]${NC}"

    echo ""
    printf "  %-45s %s\n" "Operator" "Status"
    echo "  ──────────────────────────────────────────────────────────"
    if [ "$VIRT_INSTALLED" = "true" ]; then
        echo -e "  $ok OpenShift Virtualization Operator  → Virtualization ready"
    else
        echo -e "  $ng OpenShift Virtualization Operator  → Not installed  (00-init/01-openshift-virtualization.md)"
    fi
    if [ "$MTV_INSTALLED" = "true" ]; then
        echo -e "  $ok Migration Toolkit for Virt Operator → MTV ready"
    else
        echo -e "  $ng Migration Toolkit for Virt Operator → Not installed"
    fi
    if [ "$NMSTATE_INSTALLED" = "true" ] && [ "${NMSTATE_CR_EXISTS:-false}" = "true" ]; then
        echo -e "  $ok Kubernetes NMState Operator        → NodeNetworkState available"
    elif [ "$NMSTATE_INSTALLED" = "true" ]; then
        echo -e "  $wa Kubernetes NMState Operator        → NMState CR missing (apply nmstate-cr.yaml)  (00-init/08-nmstate-operator.md)"
    else
        echo -e "  $ng Kubernetes NMState Operator        → NNCP/NNS unavailable  (00-init/08-nmstate-operator.md)"
    fi
    if [ "$DESCHEDULER_INSTALLED" = "true" ]; then
        echo -e "  $ok Kube Descheduler Operator          → Descheduler ready"
    else
        echo -e "  $ng Kube Descheduler Operator          → Skipped  (00-init/05-descheduler-operator.md)"
    fi
    if [ "$OADP_INSTALLED" = "true" ]; then
        echo -e "  $ok OADP Operator                      → Backup/Restore ready"
    else
        echo -e "  $ng OADP Operator                      → Skipped  (00-init/02-oadp-operator.md)"
    fi
    if [ "$GRAFANA_INSTALLED" = "true" ]; then
        echo -e "  $ok Grafana Operator                   → Grafana dashboard ready"
    else
        echo -e "  $ng Grafana Operator                   → Skipped  (00-init/09-grafana-operator.md)"
    fi
    if [ "$FAR_INSTALLED" = "true" ]; then
        echo -e "  $ok Fence Agents Remediation Operator  → FAR ready"
    else
        echo -e "  $ng Fence Agents Remediation Operator  → Skipped  (00-init/03-far-operator.md)"
    fi
    if [ "$NMO_INSTALLED" = "true" ]; then
        echo -e "  $ok Node Maintenance Operator          → Node maintenance ready"
    else
        echo -e "  $ng Node Maintenance Operator          → Skipped  (00-init/07-node-maintenance-operator.md)"
    fi
    if [ "$NHC_INSTALLED" = "true" ]; then
        echo -e "  $ok Node Health Check Operator         → NHC ready"
    else
        echo -e "  $ng Node Health Check Operator         → Skipped  (00-init/06-nhc-operator.md)"
    fi
    if [ "$SNR_INSTALLED" = "true" ]; then
        echo -e "  $ok Self Node Remediation Operator     → SNR ready"
    else
        echo -e "  $ng Self Node Remediation Operator     → Skipped  (00-init/04-snr-operator.md)"
    fi
    echo "  ──────────────────────────────────────────────────────────"
    echo ""
}

# Auto-detect cluster information
auto_detect_cluster() {
    if check_oc; then
        DETECTED_API=$(oc whoami --show-server 2>/dev/null || echo "")
        DETECTED_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null | sed 's/^apps\.//' || echo "")
        if [ -n "$DETECTED_API" ]; then
            print_info "Detected API server: $DETECTED_API"
        fi
        if [ -n "$DETECTED_DOMAIN" ]; then
            print_info "Detected cluster domain: $DETECTED_DOMAIN"
        fi

        # Storage class auto-detection: virtualization-specific → ceph-rbd → default
        DETECTED_SC=$(oc get sc -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | \
            grep -i "virtualization" | head -1 || true)
        if [ -z "$DETECTED_SC" ]; then
            DETECTED_SC=$(oc get sc -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | \
                grep -i "ceph-rbd" | head -1 || true)
        fi
        if [ -z "$DETECTED_SC" ]; then
            DETECTED_SC=$(oc get sc -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null || echo "")
        fi
        if [ -n "$DETECTED_SC" ]; then
            print_info "Detected storage class: $DETECTED_SC"
        fi
        ALL_SC=$(oc get sc -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | tr '\n' ' ' || echo "")
        if [ -n "$ALL_SC" ]; then
            print_info "Available storage classes: $ALL_SC"
        fi

        # Node network interface auto-detection
        # Method 1: NodeNetworkState (NMState operator, fast)
        FIRST_WORKER_FOR_NNS=$(oc get nodes -l node-role.kubernetes.io/worker \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        DETECTED_IFACES=""
        if [ -n "$FIRST_WORKER_FOR_NNS" ]; then
            DETECTED_IFACES=$(oc get nns "$FIRST_WORKER_FOR_NNS" \
                -o jsonpath='{range .status.currentState.interfaces[?(@.type=="ethernet")]}{.name}{"\n"}{end}' \
                2>/dev/null | grep -vE '^(br-ex|ovs-system)' | tr '\n' ' ' | xargs || true)
        fi
        # Method 2: oc debug node (fallback, slow ~30s)
        if [ -z "$DETECTED_IFACES" ] && [ -n "$FIRST_WORKER_FOR_NNS" ]; then
            if [ "${NMSTATE_INSTALLED:-false}" = "true" ] && [ "${NMSTATE_CR_EXISTS:-false}" != "true" ]; then
                print_warn "NMState Operator is installed but NMState CR is missing."
                print_info "To enable NodeNetworkState: oc apply -f - <<'EOF'
apiVersion: nmstate.io/v1
kind: NMState
metadata:
  name: nmstate
EOF"
            fi
            print_info "NodeNetworkState not found → detecting via oc debug node (~30s)..."
            DETECTED_IFACES=$(oc debug node/"$FIRST_WORKER_FOR_NNS" -- \
                chroot /host ip -o link show 2>/dev/null | \
                awk -F': ' '{print $2}' | \
                grep -vE '^(lo|ovs-system|br-ex|br-int|genev_sys|veth|tun|docker|ovn)' | \
                grep -E '^(ens|eth|eno|enp|em|bond)' | tr '\n' ' ' | xargs || true)
        fi
        DETECTED_IFACE=$(echo "$DETECTED_IFACES" | awk '{print $1}')
        if [ -n "$DETECTED_IFACES" ]; then
            print_info "Detected network interfaces (node: $FIRST_WORKER_FOR_NNS): $DETECTED_IFACES"
        fi
    else
        DETECTED_API=""
        DETECTED_DOMAIN=""
        DETECTED_SC=""
        DETECTED_IFACE=""
        DETECTED_IFACES=""
    fi
}

# =============================================================================
# Main
# =============================================================================

echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  OpenShift Virtualization POC Setup${NC}"
echo -e "${GREEN}  virt-poc-sample setup.sh${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""

# Check existing env.conf
if [ -f "$ENV_FILE" ]; then
    print_warn "env.conf already exists."
    echo -n -e "${YELLOW}  Overwrite? (y/N): ${NC}"
    read overwrite
    if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
        print_info "Setup cancelled. Using existing env.conf."
        exit 0
    fi
fi

# Auto-detect cluster
auto_detect_cluster

# Check operators
check_operators

# =============================================================================
# 1. Cluster Basic Info
# =============================================================================
print_header "1. Cluster Basic Info"

ask "Cluster base domain (e.g. example.com)" "${DETECTED_DOMAIN:-example.com}" CLUSTER_DOMAIN
ask "API server URL" "${DETECTED_API:-https://api.${CLUSTER_DOMAIN}:6443}" CLUSTER_API

# =============================================================================
# 2. Network Settings (NNCP / NAD)
# =============================================================================
print_header "2. Network Settings (NNCP / NAD)"

if [ -n "${DETECTED_IFACES:-}" ]; then
    print_info "Detected interfaces: $DETECTED_IFACES"
else
    print_info "Check node interfaces: oc debug node/<node> -- ip link show"
fi
ask "Node network interface for NNCP (e.g. ens4, eth1)" "${DETECTED_IFACE:-ens4}" BRIDGE_INTERFACE
ask "Linux Bridge name to create" "br1" BRIDGE_NAME
ask "NAD namespace" "poc-nad" NAD_NAMESPACE

# =============================================================================
# 3. MinIO Settings
# =============================================================================
print_header "3. MinIO Settings (OADP S3 backend)"

ask "MinIO Access Key" "minio" MINIO_ACCESS_KEY
ask "MinIO Secret Key" "minio123" MINIO_SECRET_KEY "true"
ask "OADP backup bucket name" "velero" MINIO_BUCKET
ask "MinIO service endpoint" "http://minio.poc-minio.svc.cluster.local:9000" MINIO_ENDPOINT

# =============================================================================
# 4. Storage Class
# =============================================================================
print_header "4. Storage Class"

ask "Storage class for VM image upload" "${DETECTED_SC:-ocs-external-storagecluster-ceph-rbd}" STORAGE_CLASS

# =============================================================================
# 5. VDDK Image
# =============================================================================
print_header "5. VDDK Image"

print_info "How to push VDDK image to internal registry: 01-environment/image-registry/README.md"
ask "VDDK image path" "image-registry.openshift-image-registry.svc:5000/openshift/vddk:latest" VDDK_IMAGE

# =============================================================================
# 6. Console / API Access CIDR
# =============================================================================
print_header "6. Console / API Access CIDR"

ask "Console allowed CIDRs (comma-separated, e.g. 10.0.0.0/8,192.168.1.0/24)" "0.0.0.0/0" CONSOLE_ALLOWED_CIDRS
ask "API server allowed CIDRs (comma-separated)" "0.0.0.0/0" API_ALLOWED_CIDRS

# =============================================================================
# 7. Fence Agents Remediation
# =============================================================================
print_header "7. Fence Agents Remediation (FAR)"

ask "IPMI/BMC IP address" "192.168.1.100" FENCE_AGENT_IP
ask "IPMI username" "admin" FENCE_AGENT_USER
ask "IPMI password" "password" FENCE_AGENT_PASS "true"

# =============================================================================
# 8. Node Info
# =============================================================================
print_header "8. Node Info"

# Auto-detect worker nodes
if check_oc 2>/dev/null; then
    DETECTED_WORKERS=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$DETECTED_WORKERS" ]; then
        print_info "Detected worker nodes: $DETECTED_WORKERS"
        FIRST_WORKER=$(echo $DETECTED_WORKERS | awk '{print $1}')
    else
        FIRST_WORKER="worker-0"
    fi
else
    DETECTED_WORKERS=""
    FIRST_WORKER="worker-0"
fi

ask "Worker node names (space-separated)" "${DETECTED_WORKERS:-worker-0 worker-1 worker-2}" WORKER_NODES
ask "Single node name for testing" "${FIRST_WORKER:-worker-0}" TEST_NODE

# =============================================================================
# 9. Grafana
# =============================================================================
print_header "9. Grafana"

ask "Grafana admin password" "grafana123" GRAFANA_ADMIN_PASS "true"

# =============================================================================
# Save env.conf
# =============================================================================
print_header "Saving env.conf..."

cat > "$ENV_FILE" << EOF
# =============================================================================
# virt-poc-sample environment configuration
# Auto-generated by setup.sh: $(date)
# This file is listed in .gitignore and will not be committed to git.
# =============================================================================

# Cluster basic info
CLUSTER_DOMAIN=${CLUSTER_DOMAIN}
CLUSTER_API=${CLUSTER_API}

# Network settings
BRIDGE_INTERFACE=${BRIDGE_INTERFACE}
BRIDGE_NAME=${BRIDGE_NAME}
NAD_NAMESPACE=${NAD_NAMESPACE}

# MinIO settings
MINIO_ACCESS_KEY=${MINIO_ACCESS_KEY}
MINIO_SECRET_KEY=${MINIO_SECRET_KEY}
MINIO_BUCKET=${MINIO_BUCKET}
MINIO_ENDPOINT=${MINIO_ENDPOINT}

# Storage class
STORAGE_CLASS=${STORAGE_CLASS}

# VDDK image
VDDK_IMAGE=${VDDK_IMAGE}

# Console / API access CIDR
CONSOLE_ALLOWED_CIDRS=${CONSOLE_ALLOWED_CIDRS}
API_ALLOWED_CIDRS=${API_ALLOWED_CIDRS}

# Fence Agents Remediation
FENCE_AGENT_IP=${FENCE_AGENT_IP}
FENCE_AGENT_USER=${FENCE_AGENT_USER}
FENCE_AGENT_PASS=${FENCE_AGENT_PASS}

# Node info
WORKER_NODES="${WORKER_NODES}"
TEST_NODE=${TEST_NODE}

# Grafana
GRAFANA_ADMIN_PASS=${GRAFANA_ADMIN_PASS}

# Operator installation status (auto-detected by setup.sh)
VIRT_INSTALLED=${VIRT_INSTALLED:-false}
MTV_INSTALLED=${MTV_INSTALLED:-false}
NMSTATE_INSTALLED=${NMSTATE_INSTALLED:-false}
OADP_INSTALLED=${OADP_INSTALLED:-false}
GRAFANA_INSTALLED=${GRAFANA_INSTALLED:-false}
DESCHEDULER_INSTALLED=${DESCHEDULER_INSTALLED:-false}
FAR_INSTALLED=${FAR_INSTALLED:-false}
NMO_INSTALLED=${NMO_INSTALLED:-false}
NHC_INSTALLED=${NHC_INSTALLED:-false}
SNR_INSTALLED=${SNR_INSTALLED:-false}
EOF

print_ok "env.conf created: $ENV_FILE"

# =============================================================================
# Generate rendered YAMLs
# =============================================================================
print_header "Generating rendered YAMLs..."

RENDERED_DIR="./rendered"

# Clean existing rendered directory
if [ -d "$RENDERED_DIR" ]; then
    rm -rf "$RENDERED_DIR"
fi

# Load env.conf
set -a
# shellcheck source=./env.conf
source "$ENV_FILE"
set +a

RENDERED_COUNT=0

# Build allowed variable list from env.conf (protect OpenShift Template parameters)
# Only variables defined in env.conf are substituted; ${NAME}, ${NAMESPACE} etc. are left as-is
ALLOWED_VARS=$(grep -E '^[A-Z_]+=' "$ENV_FILE" | cut -d= -f1 | tr '\n' ' ')

# Collect render targets: yaml files containing env var placeholders (${...})
print_info "Scanning YAML files..."
YAML_FILES=()
while IFS= read -r line; do
    YAML_FILES+=("$line")
done < <(grep -rl '\${' . --include="*.yaml" --exclude-dir=rendered 2>/dev/null | sort -u)
TOTAL_FILES=${#YAML_FILES[@]}
print_info "Found ${TOTAL_FILES} YAML files to render."
echo ""

for yaml_file in "${YAML_FILES[@]}"; do
    RENDERED_COUNT=$((RENDERED_COUNT + 1))
    rel_path="${yaml_file#./}"
    out_file="${RENDERED_DIR}/${rel_path}"
    out_dir="$(dirname "$out_file")"

    printf "  ${BLUE}[%d/%d]${NC} %s\n" "$RENDERED_COUNT" "$TOTAL_FILES" "$rel_path"
    mkdir -p "$out_dir"
    awk -v allowed="$ALLOWED_VARS" '
    BEGIN { n = split(allowed, vars, " "); for (i=1;i<=n;i++) ok[vars[i]]=1 }
    {
        while (match($0, /\$\{[A-Z_][A-Z0-9_]*\}/)) {
            varname = substr($0, RSTART+2, RLENGTH-3)
            val = (varname in ok) ? ENVIRON[varname] : "${" varname "}"
            $0 = substr($0, 1, RSTART-1) val substr($0, RSTART+RLENGTH)
        }
        print
    }' "$yaml_file" > "$out_file"
done

print_ok "Total ${RENDERED_COUNT} YAML files generated in rendered/"

# =============================================================================
# Done
# =============================================================================
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  Setup complete!${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo -e "  Next steps:"
echo -e ""
echo -e "  ${CYAN}[Pre-requisites]${NC}"
echo -e "  1. 00-init/README.md              — Operator installation guide"
echo -e "  2. 00-init/01-make-template.md     — Custom VM image creation guide"
echo -e "  3. 00-init/pvc-to-qcow2.md        — Upload qcow2 to openshift-virtualization-os-images"
echo -e ""
echo -e "  ${CYAN}[Environment Setup]${NC}"
echo -e "  4. 01-environment/README.md       — Environment configuration"
echo -e ""
echo -e "  ${CYAN}[Environment Setup — Operator dependent]${NC}"

if [ "${GRAFANA_INSTALLED:-false}" = "true" ]; then
    echo -e "  ${GREEN}[✔]${NC} 01-environment/grafana/         — Grafana dashboard ready"
else
    echo -e "  ${RED}[✘]${NC} 01-environment/grafana/         — Grafana Operator not installed  (00-init/09-grafana-operator.md)"
fi
if [ "${DESCHEDULER_INSTALLED:-false}" = "true" ]; then
    echo -e "  ${GREEN}[✔]${NC} 01-environment/descheduler/           — Descheduler test ready"
else
    echo -e "  ${RED}[✘]${NC} 01-environment/descheduler/           — Kube Descheduler Operator not installed"
fi
if [ "${FAR_INSTALLED:-false}" = "true" ]; then
    echo -e "  ${GREEN}[✔]${NC} 01-environment/far/             — FAR ready"
else
    echo -e "  ${RED}[✘]${NC} 01-environment/far/             — Fence Agents Remediation Operator not installed  (00-init/03-far-operator.md)"
fi
if [ "${NMO_INSTALLED:-false}" = "true" ]; then
    echo -e "  ${GREEN}[✔]${NC} 01-environment/node-maintenance/      — Node maintenance test ready"
else
    echo -e "  ${RED}[✘]${NC} 01-environment/node-maintenance/      — Node Maintenance Operator not installed  (00-init/07-node-maintenance-operator.md)"
fi
if [ "${NHC_INSTALLED:-false}" = "true" ]; then
    echo -e "  ${GREEN}[✔]${NC} 01-environment/nhc/             — NHC ready"
else
    echo -e "  ${RED}[✘]${NC} 01-environment/nhc/             — Node Health Check Operator not installed  (00-init/06-nhc-operator.md)"
fi
if [ "${SNR_INSTALLED:-false}" = "true" ]; then
    echo -e "  ${GREEN}[✔]${NC} 01-environment/snr/             — SNR ready"
else
    echo -e "  ${RED}[✘]${NC} 01-environment/snr/             — Self Node Remediation Operator not installed  (00-init/04-snr-operator.md)"
fi
echo ""
echo -e "  Rendered YAMLs with env vars applied:"
echo -e "  Apply files directly from the ${CYAN}rendered/${NC} directory."
echo ""
echo -e "  Example:"
echo -e "  ${YELLOW}oc apply -f rendered/01-environment/nncp/nncp-bridge.yaml${NC}"
echo ""
echo -e "  Or run ${CYAN}apply.sh${NC} in each directory."
echo ""
