#!/bin/bash
# =============================================================================
# 02-network.sh
#
# NNCP(NodeNetworkConfigurationPolicy) + NAD(NetworkAttachmentDefinition) 구성
# 4가지 네트워크 방식 중 선택하여 VM용 보조 네트워크를 구성합니다.
#
#   1. Linux Bridge          — cnv-bridge CNI, NMState NNCP
#   2. OVN Localnet          — ovn-k8s-cni-overlay, OVN bridge-mappings
#   3. Linux Bridge + VLAN   — cnv-bridge CNI + VLAN ID, trunk port
#   4. OVN Localnet + VLAN   — ovn-k8s-cni-overlay + vlanID
#
# 사용법: ./02-network.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

BRIDGE_INTERFACE="${BRIDGE_INTERFACE:-ens4}"
BRIDGE_NAME="${BRIDGE_NAME:-br1}"
NAD_NAMESPACE="poc-network"
VLAN_ID="${VLAN_ID:-100}"
SECONDARY_IP_PREFIX="${SECONDARY_IP_PREFIX:-192.168.100}"

# 모드별로 설정되는 변수
NET_TYPE=""
NNCP_NAME=""
NAD_NAME=""
OVN_LOCALNET_NAME="poc-localnet"

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

ensure_runstrategy() {
    local vm="$1" ns="$2"
    local running
    running=$(oc get vm "$vm" -n "$ns" \
        -o jsonpath='{.spec.running}' 2>/dev/null || true)
    [ -z "$running" ] && return 0
    local rs="Halted"
    [ "$running" = "true" ] && rs="Always"
    oc patch vm "$vm" -n "$ns" --type=json -p "[
      {\"op\":\"remove\",\"path\":\"/spec/running\"},
      {\"op\":\"add\",\"path\":\"/spec/runStrategy\",\"value\":\"${rs}\"}
    ]" &>/dev/null || true
}

# =============================================================================
# 네트워크 방식 선택
# =============================================================================
choose_mode() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  네트워크 구성 방식을 선택하세요${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${GREEN}1)${NC} Linux Bridge"
    echo -e "     NNCP로 Linux Bridge 생성 → cnv-bridge CNI"
    echo -e "     단순 L2 연결. 추가 스위치 설정 불필요."
    echo ""
    echo -e "  ${GREEN}2)${NC} OVN Localnet"
    echo -e "     NNCP에 OVN bridge-mappings 추가 → ovn-k8s-cni-overlay CNI"
    echo -e "     OVN이 스위칭 처리. 포트 보안·ACL 지원."
    echo ""
    echo -e "  ${GREEN}3)${NC} Linux Bridge + VLAN filtering"
    echo -e "     NNCP로 Linux Bridge trunk 포트 구성 → cnv-bridge + VLAN ID"
    echo -e "     단일 물리 NIC으로 여러 VLAN 분리."
    echo ""
    echo -e "  ${GREEN}4)${NC} OVN Localnet + VLAN"
    echo -e "     OVN bridge-mappings → ovn-k8s-cni-overlay + vlanID"
    echo -e "     OVN 포트 보안 + VLAN 분리 동시 활용."
    echo ""
    echo -e "  현재 설정:"
    echo -e "    BRIDGE_INTERFACE : ${CYAN}${BRIDGE_INTERFACE}${NC}"
    echo -e "    BRIDGE_NAME      : ${CYAN}${BRIDGE_NAME}${NC}"
    echo -e "    네임스페이스      : ${CYAN}${NAD_NAMESPACE}${NC}"
    echo ""
    read -r -p "  선택 [1-4]: " NET_TYPE

    case "$NET_TYPE" in
        1)
            NNCP_NAME="poc-bridge-nncp"
            NAD_NAME="poc-bridge-nad"
            print_ok "선택: Linux Bridge"
            ;;
        2)
            NNCP_NAME="poc-localnet-nncp"
            NAD_NAME="poc-localnet-nad"
            print_ok "선택: OVN Localnet"
            ;;
        3)
            NNCP_NAME="poc-bridge-nncp"
            NAD_NAME="poc-bridge-vlan-nad"
            echo ""
            read -r -p "  VLAN ID를 입력하세요 [기본값: ${VLAN_ID}]: " input_vlan
            [ -n "$input_vlan" ] && VLAN_ID="$input_vlan"
            print_ok "선택: Linux Bridge + VLAN ${VLAN_ID}"
            ;;
        4)
            NNCP_NAME="poc-localnet-nncp"
            NAD_NAME="poc-localnet-vlan-nad"
            echo ""
            read -r -p "  VLAN ID를 입력하세요 [기본값: ${VLAN_ID}]: " input_vlan
            [ -n "$input_vlan" ] && VLAN_ID="$input_vlan"
            print_ok "선택: OVN Localnet + VLAN ${VLAN_ID}"
            ;;
        *)
            print_error "1~4 사이의 값을 입력하세요."
            exit 1
            ;;
    esac
}

# =============================================================================
# 사전 확인
# =============================================================================
preflight() {
    print_step "사전 확인"

    if ! oc whoami &>/dev/null; then
        print_error "OpenShift에 로그인되어 있지 않습니다."
        exit 1
    fi
    print_ok "클러스터 접속: $(oc whoami) @ $(oc whoami --show-server)"

    if [ "${NMSTATE_INSTALLED:-false}" != "true" ]; then
        if ! oc get csv -A 2>/dev/null | grep -qi "kubernetes-nmstate"; then
            print_warn "Kubernetes NMState Operator 미설치 → 건너뜁니다."
            print_warn "  설치 가이드: 00-operator/nmstate-operator.md"
            exit 77
        fi
    fi
    print_ok "NMState Operator 확인"

    if ! oc get nmstate 2>/dev/null | grep -q "."; then
        print_warn "NMState CR이 없습니다. NMState 인스턴스를 생성합니다..."
        cat > nmstate-cr.yaml <<'NMEOF'
apiVersion: nmstate.io/v1
kind: NMState
metadata:
  name: nmstate
NMEOF
        oc apply -f nmstate-cr.yaml
        print_info "NMState 핸들러 준비 대기 중 (최대 60초)..."
        oc rollout status daemonset/nmstate-handler -n openshift-nmstate --timeout=60s 2>/dev/null || true
        print_ok "NMState CR 생성 완료"
    else
        print_ok "NMState CR 확인"
    fi
}

# =============================================================================
# NNCP — 방식별 적용
# =============================================================================
_wait_nncp() {
    local name="$1"
    print_info "NNCP 적용 완료 — 노드 설정 전파 대기 중..."
    local retries=24 i=0
    while [ "$i" -lt "$retries" ]; do
        local status reason
        status=$(oc get nncp "$name" \
            -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")
        if [ "$status" = "True" ]; then
            print_ok "NNCP ${name} Available"
            break
        fi
        reason=$(oc get nncp "$name" \
            -o jsonpath='{.status.conditions[?(@.type=="Available")].reason}' 2>/dev/null || echo "")
        printf "  [%d/%d] 상태 대기 중... (%s)\r" "$((i+1))" "$retries" "${reason:-Pending}"
        sleep 5
        i=$((i+1))
    done
    echo ""
    if [ "$i" -eq "$retries" ]; then
        print_warn "NNCP 적용 시간 초과. 상태를 직접 확인하세요: oc get nncp / oc get nnce"
    fi
    print_info "노드별 적용 상태 (NNCE):"
    oc get nnce 2>/dev/null | grep "$name" | \
        awk '{printf "    %-40s %s\n", $1, $2}' || true
}

step_nncp_linux_bridge() {
    print_step "1/4  NNCP — Linux Bridge (${BRIDGE_NAME} ← ${BRIDGE_INTERFACE})"

    cat > nncp-${NNCP_NAME}.yaml <<EOF
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: ${NNCP_NAME}
spec:
  nodeSelector:
    node-role.kubernetes.io/worker: ''
  desiredState:
    interfaces:
      - name: ${BRIDGE_NAME}
        description: Linux bridge with ${BRIDGE_INTERFACE} as a port
        type: linux-bridge
        state: up
        ipv4:
          enabled: false
        ipv6:
          enabled: false
        bridge:
          options:
            stp:
              enabled: false
          port:
            - name: ${BRIDGE_INTERFACE}
EOF
    echo "생성된 파일: nncp-${NNCP_NAME}.yaml"
    oc apply -f nncp-${NNCP_NAME}.yaml
    _wait_nncp "$NNCP_NAME"
}

step_nncp_linux_bridge_vlan() {
    print_step "1/4  NNCP — Linux Bridge + VLAN trunk (${BRIDGE_NAME} ← ${BRIDGE_INTERFACE}, VLAN ${VLAN_ID})"

    cat > nncp-${NNCP_NAME}.yaml <<EOF
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: ${NNCP_NAME}
spec:
  nodeSelector:
    node-role.kubernetes.io/worker: ''
  desiredState:
    interfaces:
      - name: ${BRIDGE_NAME}
        description: Linux bridge (VLAN trunk) with ${BRIDGE_INTERFACE} as a port
        type: linux-bridge
        state: up
        ipv4:
          enabled: false
        ipv6:
          enabled: false
        bridge:
          options:
            stp:
              enabled: false
          port:
            - name: ${BRIDGE_INTERFACE}
              vlan:
                mode: trunk
                trunk-tags:
                  - id-range:
                      min: 1
                      max: 4094
EOF
    echo "생성된 파일: nncp-${NNCP_NAME}.yaml"
    oc apply -f nncp-${NNCP_NAME}.yaml
    _wait_nncp "$NNCP_NAME"
}

step_nncp_ovn_localnet() {
    print_step "1/4  NNCP — OVN Localnet bridge-mappings (${BRIDGE_NAME} ← ${BRIDGE_INTERFACE})"

    cat > nncp-${NNCP_NAME}.yaml <<EOF
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: ${NNCP_NAME}
spec:
  nodeSelector:
    node-role.kubernetes.io/worker: ''
  desiredState:
    interfaces:
      - name: ${BRIDGE_NAME}
        description: OVN Localnet bridge with ${BRIDGE_INTERFACE} as a port
        type: linux-bridge
        state: up
        ipv4:
          enabled: false
        ipv6:
          enabled: false
        bridge:
          options:
            stp:
              enabled: false
          port:
            - name: ${BRIDGE_INTERFACE}
    ovn:
      bridge-mappings:
        - localnet: ${OVN_LOCALNET_NAME}
          bridge: ${BRIDGE_NAME}
          state: present
EOF
    echo "생성된 파일: nncp-${NNCP_NAME}.yaml"
    oc apply -f nncp-${NNCP_NAME}.yaml
    _wait_nncp "$NNCP_NAME"
}

step_nncp() {
    case "$NET_TYPE" in
        1) step_nncp_linux_bridge ;;
        2) step_nncp_ovn_localnet ;;
        3) step_nncp_linux_bridge_vlan ;;
        4) step_nncp_ovn_localnet ;;
    esac
}

# =============================================================================
# NAD — 방식별 등록
# =============================================================================
_ensure_namespace() {
    oc new-project "${NAD_NAMESPACE}" >/dev/null 2>&1 || \
        oc project "${NAD_NAMESPACE}" >/dev/null 2>&1 || true
    print_ok "네임스페이스: ${NAD_NAMESPACE}"
}

step_nad_linux_bridge() {
    print_step "2/4  NAD — Linux Bridge (cnv-bridge)"
    _ensure_namespace

    cat > nad-${NAD_NAME}.yaml <<EOF
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: ${NAD_NAME}
  namespace: ${NAD_NAMESPACE}
  annotations:
    k8s.v1.cni.cncf.io/resourceName: bridge.network.kubevirt.io/${BRIDGE_NAME}
spec:
  config: '{"cniVersion":"0.3.1","name":"${NAD_NAME}","type":"cnv-bridge","bridge":"${BRIDGE_NAME}","macspoofchk":true,"ipam":{}}'
EOF
    echo "생성된 파일: nad-${NAD_NAME}.yaml"
    oc apply -f nad-${NAD_NAME}.yaml
    print_ok "NAD ${NAD_NAME} 등록 완료"
}

step_nad_linux_bridge_vlan() {
    print_step "2/4  NAD — Linux Bridge + VLAN ${VLAN_ID} (cnv-bridge)"
    _ensure_namespace

    cat > nad-${NAD_NAME}.yaml <<EOF
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: ${NAD_NAME}
  namespace: ${NAD_NAMESPACE}
  annotations:
    k8s.v1.cni.cncf.io/resourceName: bridge.network.kubevirt.io/${BRIDGE_NAME}
spec:
  config: '{"cniVersion":"0.3.1","name":"${NAD_NAME}","type":"cnv-bridge","bridge":"${BRIDGE_NAME}","vlan":${VLAN_ID},"macspoofchk":true,"ipam":{}}'
EOF
    echo "생성된 파일: nad-${NAD_NAME}.yaml"
    oc apply -f nad-${NAD_NAME}.yaml
    print_ok "NAD ${NAD_NAME} 등록 완료 (VLAN ${VLAN_ID})"
}

step_nad_ovn_localnet() {
    print_step "2/4  NAD — OVN Localnet (ovn-k8s-cni-overlay)"
    _ensure_namespace

    cat > nad-${NAD_NAME}.yaml <<EOF
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: ${NAD_NAME}
  namespace: ${NAD_NAMESPACE}
spec:
  config: '{"cniVersion":"0.3.1","name":"${OVN_LOCALNET_NAME}","type":"ovn-k8s-cni-overlay","topology":"localnet","netAttachDefName":"${NAD_NAMESPACE}/${NAD_NAME}"}'
EOF
    echo "생성된 파일: nad-${NAD_NAME}.yaml"
    oc apply -f nad-${NAD_NAME}.yaml
    print_ok "NAD ${NAD_NAME} 등록 완료"
}

step_nad_ovn_localnet_vlan() {
    print_step "2/4  NAD — OVN Localnet + VLAN ${VLAN_ID} (ovn-k8s-cni-overlay)"
    _ensure_namespace

    cat > nad-${NAD_NAME}.yaml <<EOF
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: ${NAD_NAME}
  namespace: ${NAD_NAMESPACE}
spec:
  config: '{"cniVersion":"0.3.1","name":"${OVN_LOCALNET_NAME}","type":"ovn-k8s-cni-overlay","topology":"localnet","netAttachDefName":"${NAD_NAMESPACE}/${NAD_NAME}","vlanID":${VLAN_ID}}'
EOF
    echo "생성된 파일: nad-${NAD_NAME}.yaml"
    oc apply -f nad-${NAD_NAME}.yaml
    print_ok "NAD ${NAD_NAME} 등록 완료 (VLAN ${VLAN_ID})"
}

step_nad() {
    case "$NET_TYPE" in
        1) step_nad_linux_bridge ;;
        2) step_nad_ovn_localnet ;;
        3) step_nad_linux_bridge_vlan ;;
        4) step_nad_ovn_localnet_vlan ;;
    esac
}

# =============================================================================
# VM 생성 (poc 템플릿 + 선택된 NAD)
# =============================================================================
step_vm() {
    print_step "3/4  VM 생성 (poc 템플릿 + ${NAD_NAME})"

    if ! oc get template poc -n openshift &>/dev/null; then
        print_warn "poc Template 없음 — VM 생성을 건너뜁니다. (01-template 먼저 실행 필요)"
        return
    fi

    local ip_suffixes=(10 11)
    local idx=0

    for suffix in 1 2; do
        local VM_NAME="poc-network-vm-${suffix}"
        local ip_suffix="${ip_suffixes[$idx]}"
        idx=$((idx + 1))

        if oc get vm "$VM_NAME" -n "$NAD_NAMESPACE" &>/dev/null; then
            print_ok "VM $VM_NAME 이미 존재 — 스킵"
            continue
        fi

        oc process -n openshift poc -p NAME="$VM_NAME" | \
            sed 's/  running: false/  runStrategy: Halted/' > "vm-${VM_NAME}.yaml"
        echo "생성된 파일: vm-${VM_NAME}.yaml"
        oc apply -n "$NAD_NAMESPACE" -f "vm-${VM_NAME}.yaml"

        ensure_runstrategy "$VM_NAME" "$NAD_NAMESPACE"

        # 보조 NIC (NAD) 추가
        oc patch vm "$VM_NAME" -n "$NAD_NAMESPACE" --type=json -p='[
          {
            "op": "add",
            "path": "/spec/template/spec/domain/devices/interfaces/-",
            "value": {"name": "bridge-net", "bridge": {}, "model": "virtio"}
          },
          {
            "op": "add",
            "path": "/spec/template/spec/networks/-",
            "value": {"name": "bridge-net", "multus": {"networkName": "'"${NAD_NAME}"'"}}
          }
        ]'

        # cloud-init networkData — secondary NIC(eth1) 정적 IP 설정
        oc patch vm "$VM_NAME" -n "$NAD_NAMESPACE" --type=json -p="[
          {
            \"op\": \"add\",
            \"path\": \"/spec/template/spec/domain/devices/disks/-\",
            \"value\": {\"name\": \"cloudinit\", \"disk\": {\"bus\": \"virtio\"}}
          },
          {
            \"op\": \"add\",
            \"path\": \"/spec/template/spec/volumes/-\",
            \"value\": {
              \"name\": \"cloudinit\",
              \"cloudInitNoCloud\": {
                \"networkData\": \"version: 2\\nethernets:\\n  eth1:\\n    dhcp4: false\\n    addresses:\\n      - ${SECONDARY_IP_PREFIX}.${ip_suffix}/24\\n    gateway4: ${SECONDARY_IP_PREFIX}.1\\n    nameservers:\\n      addresses:\\n        - 8.8.8.8\\n\"
              }
            }
          }
        ]"

        virtctl start "$VM_NAME" -n "$NAD_NAMESPACE" 2>/dev/null || true
        print_ok "VM ${VM_NAME} 생성 완료 (eth0: masquerade, eth1: ${NAD_NAME}, IP: ${SECONDARY_IP_PREFIX}.${ip_suffix}/24)"
    done
}

# =============================================================================
# ConsoleYAMLSample 등록
# =============================================================================
step_consoleyamlsamples() {
    print_step "4/4  ConsoleYAMLSample 등록"

    # NNCP 샘플 — 방식별
    local nncp_title nncp_desc nncp_yaml
    case "$NET_TYPE" in
        1)
            nncp_title="POC Linux Bridge NNCP"
            nncp_desc="워커 노드에 Linux Bridge(${BRIDGE_NAME})를 생성합니다."
            nncp_yaml="$(cat <<YAML
    apiVersion: nmstate.io/v1
    kind: NodeNetworkConfigurationPolicy
    metadata:
      name: ${NNCP_NAME}
    spec:
      nodeSelector:
        node-role.kubernetes.io/worker: ""
      desiredState:
        interfaces:
          - name: ${BRIDGE_NAME}
            type: linux-bridge
            state: up
            ipv4:
              enabled: false
            bridge:
              options:
                stp:
                  enabled: false
              port:
                - name: ${BRIDGE_INTERFACE}
YAML
)"
            ;;
        2|4)
            nncp_title="POC OVN Localnet NNCP"
            nncp_desc="OVN bridge-mappings로 ${BRIDGE_NAME}을 ${OVN_LOCALNET_NAME}에 매핑합니다."
            nncp_yaml="$(cat <<YAML
    apiVersion: nmstate.io/v1
    kind: NodeNetworkConfigurationPolicy
    metadata:
      name: ${NNCP_NAME}
    spec:
      nodeSelector:
        node-role.kubernetes.io/worker: ""
      desiredState:
        interfaces:
          - name: ${BRIDGE_NAME}
            type: linux-bridge
            state: up
            ipv4:
              enabled: false
            bridge:
              options:
                stp:
                  enabled: false
              port:
                - name: ${BRIDGE_INTERFACE}
        ovn:
          bridge-mappings:
            - localnet: ${OVN_LOCALNET_NAME}
              bridge: ${BRIDGE_NAME}
              state: present
YAML
)"
            ;;
        3)
            nncp_title="POC Linux Bridge VLAN trunk NNCP"
            nncp_desc="워커 노드에 VLAN trunk 포트로 Linux Bridge(${BRIDGE_NAME})를 생성합니다."
            nncp_yaml="$(cat <<YAML
    apiVersion: nmstate.io/v1
    kind: NodeNetworkConfigurationPolicy
    metadata:
      name: ${NNCP_NAME}
    spec:
      nodeSelector:
        node-role.kubernetes.io/worker: ""
      desiredState:
        interfaces:
          - name: ${BRIDGE_NAME}
            type: linux-bridge
            state: up
            ipv4:
              enabled: false
            bridge:
              options:
                stp:
                  enabled: false
              port:
                - name: ${BRIDGE_INTERFACE}
                  vlan:
                    mode: trunk
                    trunk-tags:
                      - id-range:
                          min: 1
                          max: 4094
YAML
)"
            ;;
    esac

    cat > consoleyamlsample-nncp.yaml <<EOF
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: ${NNCP_NAME}
spec:
  title: "${nncp_title}"
  description: "${nncp_desc}"
  targetResource:
    apiVersion: nmstate.io/v1
    kind: NodeNetworkConfigurationPolicy
  yaml: |
${nncp_yaml}
EOF
    echo "생성된 파일: consoleyamlsample-nncp.yaml"
    oc apply -f consoleyamlsample-nncp.yaml
    print_ok "ConsoleYAMLSample ${NNCP_NAME} 등록 완료"

    # NAD 샘플
    local nad_config
    case "$NET_TYPE" in
        1) nad_config="{\"cniVersion\":\"0.3.1\",\"name\":\"${NAD_NAME}\",\"type\":\"cnv-bridge\",\"bridge\":\"${BRIDGE_NAME}\",\"macspoofchk\":true,\"ipam\":{}}" ;;
        2) nad_config="{\"cniVersion\":\"0.3.1\",\"name\":\"${OVN_LOCALNET_NAME}\",\"type\":\"ovn-k8s-cni-overlay\",\"topology\":\"localnet\",\"netAttachDefName\":\"${NAD_NAMESPACE}/${NAD_NAME}\"}" ;;
        3) nad_config="{\"cniVersion\":\"0.3.1\",\"name\":\"${NAD_NAME}\",\"type\":\"cnv-bridge\",\"bridge\":\"${BRIDGE_NAME}\",\"vlan\":${VLAN_ID},\"macspoofchk\":true,\"ipam\":{}}" ;;
        4) nad_config="{\"cniVersion\":\"0.3.1\",\"name\":\"${OVN_LOCALNET_NAME}\",\"type\":\"ovn-k8s-cni-overlay\",\"topology\":\"localnet\",\"netAttachDefName\":\"${NAD_NAMESPACE}/${NAD_NAME}\",\"vlanID\":${VLAN_ID}}" ;;
    esac

    cat > consoleyamlsample-nad.yaml <<EOF
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: ${NAD_NAME}
spec:
  title: "POC NAD — ${NAD_NAME}"
  description: "NNCP 적용 후 VM 보조 네트워크로 등록합니다. (방식: $(echo "$NET_TYPE" | sed 's/1/Linux Bridge/;s/2/OVN Localnet/;s/3/Linux Bridge+VLAN/;s/4/OVN Localnet+VLAN/'))"
  targetResource:
    apiVersion: k8s.cni.cncf.io/v1
    kind: NetworkAttachmentDefinition
  yaml: |
    apiVersion: k8s.cni.cncf.io/v1
    kind: NetworkAttachmentDefinition
    metadata:
      name: ${NAD_NAME}
      namespace: ${NAD_NAMESPACE}
    spec:
      config: '${nad_config}'
EOF
    echo "생성된 파일: consoleyamlsample-nad.yaml"
    oc apply -f consoleyamlsample-nad.yaml
    print_ok "ConsoleYAMLSample ${NAD_NAME} 등록 완료"
}

# =============================================================================
# 완료 요약
# =============================================================================
print_summary() {
    local mode_label
    case "$NET_TYPE" in
        1) mode_label="Linux Bridge" ;;
        2) mode_label="OVN Localnet" ;;
        3) mode_label="Linux Bridge + VLAN ${VLAN_ID}" ;;
        4) mode_label="OVN Localnet + VLAN ${VLAN_ID}" ;;
    esac

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  완료! 네트워크 구성 (${mode_label})${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  NNCP 상태 : ${CYAN}oc get nncp${NC}"
    echo -e "  NNCE 상태 : ${CYAN}oc get nnce${NC}"
    echo -e "  NAD 확인  : ${CYAN}oc get net-attach-def -n ${NAD_NAMESPACE}${NC}"
    echo -e "  VM 상태   : ${CYAN}oc get vm,vmi -n ${NAD_NAMESPACE}${NC}"
    echo ""
    echo -e "  VM IP (eth1):"
    echo -e "    poc-network-vm-1 : ${CYAN}${SECONDARY_IP_PREFIX}.10/24${NC}"
    echo -e "    poc-network-vm-2 : ${CYAN}${SECONDARY_IP_PREFIX}.11/24${NC}"
    echo ""
}

# =============================================================================
# 메인
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  02-network: NNCP + NAD + VM 구성${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    choose_mode
    preflight
    step_nncp
    step_nad
    step_vm
    step_consoleyamlsamples
    print_summary
}

main
