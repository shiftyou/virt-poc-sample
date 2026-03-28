#!/bin/bash
# =============================================================================
# 02-network.sh
#
# NNCP(NodeNetworkConfigurationPolicy) + NAD(NetworkAttachmentDefinition) 구성
# 워커 노드에 Linux Bridge를 생성하고 VM용 보조 네트워크를 등록합니다.
#
# 사용법: ./02-network.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# env.conf 자동 로드 (단독 실행 시)
ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

BRIDGE_INTERFACE="${BRIDGE_INTERFACE}"
BRIDGE_NAME="${BRIDGE_NAME}"
NAD_NAMESPACE="${NAD_NAMESPACE}"

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
# 사전 확인
# =============================================================================
preflight() {
    print_step "사전 확인"

    print_ok "설정 확인"
    print_info "  BRIDGE_INTERFACE : ${BRIDGE_INTERFACE}"
    print_info "  BRIDGE_NAME      : ${BRIDGE_NAME}"
    print_info "  NAD_NAMESPACE    : ${NAD_NAMESPACE}"

    if ! oc whoami &>/dev/null; then
        print_error "OpenShift 에 로그인되어 있지 않습니다."
        exit 1
    fi
    print_ok "클러스터 접속: $(oc whoami) @ $(oc whoami --show-server)"

    # NMState Operator 확인 (env.conf의 NMSTATE_INSTALLED 우선, 없으면 직접 확인)
    if [ "${NMSTATE_INSTALLED:-false}" != "true" ]; then
        if ! oc get csv -A 2>/dev/null | grep -qi "kubernetes-nmstate"; then
            print_warn "Kubernetes NMState Operator 미설치 → 건너뜁니다."
            print_warn "  설치 가이드: 00-operator/nmstate-operator.md"
            exit 77
        fi
    fi
    print_ok "NMState Operator 확인"

    # NMState CR 확인
    if ! oc get nmstate 2>/dev/null | grep -q "."; then
        print_warn "NMState CR 이 없습니다. NMState 인스턴스를 생성합니다..."
        cat > nmstate-cr.yaml <<'NMEOF'
apiVersion: nmstate.io/v1
kind: NMState
metadata:
  name: nmstate
NMEOF
        echo "생성된 파일: nmstate-cr.yaml"
        oc apply -f nmstate-cr.yaml
        print_info "NMState 핸들러 준비 대기 중 (최대 60초)..."
        oc rollout status daemonset/nmstate-handler -n openshift-nmstate --timeout=60s 2>/dev/null || true
        print_ok "NMState CR 생성 완료"
    else
        print_ok "NMState CR 확인"
    fi
}

# =============================================================================
# 1단계: NNCP — Linux Bridge 생성
# =============================================================================
step_nncp() {
    print_step "1/4  NNCP — Linux Bridge 생성 (${BRIDGE_NAME} ← ${BRIDGE_INTERFACE})"

    # 기존 NNCP가 진행 중이면 포트 이름을 표시하고 완료될 때까지 대기 (admission webhook 충돌 방지)
    if oc get nncp poc-bridge-nncp &>/dev/null; then
        local pre_status
        pre_status=$(oc get nncp poc-bridge-nncp \
            -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")
        if [ "$pre_status" != "True" ]; then
            # 현재 NNCP에 설정된 bridge port name 표시
            local cur_port
            cur_port=$(oc get nncp poc-bridge-nncp \
                -o jsonpath='{.spec.desiredState.interfaces[0].bridge.port[0].name}' 2>/dev/null || echo "unknown")
            local cur_bridge
            cur_bridge=$(oc get nncp poc-bridge-nncp \
                -o jsonpath='{.spec.desiredState.interfaces[0].name}' 2>/dev/null || echo "unknown")
            print_info "기존 NNCP 가 노드에 전파 중입니다. 완료 대기 중..."
            print_info "  Bridge     : ${cur_bridge}"
            print_info "  Port (NIC) : ${cur_port}"
            local w=0
            while [ $w -lt 24 ]; do
                pre_status=$(oc get nncp poc-bridge-nncp \
                    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")
                [ "$pre_status" = "True" ] && break
                local reason
                reason=$(oc get nncp poc-bridge-nncp \
                    -o jsonpath='{.status.conditions[?(@.type=="Available")].reason}' 2>/dev/null || echo "")
                printf "  [%d/24] 전파 대기 중... (%s)\r" "$((w+1))" "${reason:-Pending}"
                sleep 5
                w=$((w+1))
            done
            echo ""
            if [ $w -eq 24 ]; then
                print_warn "대기 시간 초과. oc get nnce 로 노드별 상태를 확인하세요."
            else
                print_ok "기존 NNCP 전파 완료 (bridge: ${cur_bridge}, port: ${cur_port})"
            fi
        fi
    fi

    cat > nncp-poc-bridge.yaml <<EOF
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: poc-bridge-nncp
spec:
  desiredState:
    interfaces:
      - bridge:
          options:
            stp:
              enabled: false
          port:
            - name: ${BRIDGE_INTERFACE}
        description: Linux bridge with ${BRIDGE_INTERFACE} as a port
        ipv4:
          dhcp: false
          enabled: false
        name: ${BRIDGE_NAME}
        state: up
        type: linux-bridge
  nodeSelector:
    node-role.kubernetes.io/worker: ''
EOF
    echo "생성된 파일: nncp-poc-bridge.yaml"
    oc apply -f nncp-poc-bridge.yaml

    print_info "NNCP 적용 완료 — 노드 설정 전파 대기 중..."

    local retries=24
    local i=0
    while [ $i -lt $retries ]; do
        local status
        status=$(oc get nncp poc-bridge-nncp \
            -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")
        if [ "$status" = "True" ]; then
            print_ok "NNCP poc-bridge-nncp Available"
            break
        fi
        local reason
        reason=$(oc get nncp poc-bridge-nncp \
            -o jsonpath='{.status.conditions[?(@.type=="Available")].reason}' 2>/dev/null || echo "")
        printf "  [%d/%d] 상태 대기 중... (%s)\r" "$((i+1))" "$retries" "${reason:-Pending}"
        sleep 5
        i=$((i+1))
    done
    echo ""

    if [ $i -eq $retries ]; then
        print_warn "NNCP 적용 시간 초과. 상태를 직접 확인하세요:"
        echo "  oc get nncp"
        echo "  oc get nnce"
    fi

    echo ""
    print_info "노드별 적용 상태 (NNCE):"
    oc get nnce 2>/dev/null | grep "poc-bridge-nncp" | \
        awk '{printf "    %-40s %s\n", $1, $2}' || true
}

# =============================================================================
# 2단계: NAD — NetworkAttachmentDefinition 등록
# =============================================================================
step_nad() {
    print_step "2/4  NAD — NetworkAttachmentDefinition 등록 (${NAD_NAMESPACE})"

    oc new-project "${NAD_NAMESPACE}" 2>/dev/null || \
        oc project "${NAD_NAMESPACE}" 2>/dev/null || true
    print_ok "네임스페이스: ${NAD_NAMESPACE}"

    cat > nad-poc-bridge.yaml <<EOF
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: poc-bridge-nad
  namespace: ${NAD_NAMESPACE}
  annotations:
    k8s.v1.cni.cncf.io/resourceName: bridge.network.kubevirt.io/${BRIDGE_NAME}
spec:
  config: '{"cniVersion":"0.3.1","name":"poc-bridge-nad","type":"cnv-bridge","bridge":"${BRIDGE_NAME}","macspoofchk":true,"ipam":{}}'
EOF
    echo "생성된 파일: nad-poc-bridge.yaml"
    oc apply -f nad-poc-bridge.yaml

    print_ok "NAD poc-bridge-nad 등록 완료"
}

# =============================================================================
# 3단계: VM 생성 (poc 템플릿 + NAD 보조 네트워크)
# =============================================================================
step_vm() {
    print_step "3/4  VM 생성 (poc 템플릿 + poc-bridge-nad)"

    if ! oc get template poc -n openshift &>/dev/null; then
        print_warn "poc Template 없음 — VM 생성을 건너뜁니다. (01-template 먼저 실행 필요)"
        return
    fi

    local VM_NAME="poc-network-vm"

    if oc get vm "$VM_NAME" -n "$NAD_NAMESPACE" &>/dev/null; then
        print_ok "VM $VM_NAME 이미 존재 — 스킵"
        return
    fi

    # poc 템플릿으로 VM 생성
    oc process -n openshift poc -p NAME="$VM_NAME" > "vm-${VM_NAME}.yaml"
    echo "생성된 파일: vm-${VM_NAME}.yaml"
    oc apply -n "$NAD_NAMESPACE" -f "vm-${VM_NAME}.yaml"

    # 보조 NIC (poc-bridge-nad) 추가 패치
    oc patch vm "$VM_NAME" -n "$NAD_NAMESPACE" --type=json -p='[
      {
        "op": "add",
        "path": "/spec/template/spec/domain/devices/interfaces/-",
        "value": {"name": "bridge-net", "bridge": {}, "model": "virtio"}
      },
      {
        "op": "add",
        "path": "/spec/template/spec/networks/-",
        "value": {"name": "bridge-net", "multus": {"networkName": "poc-bridge-nad"}}
      }
    ]'

    virtctl start "$VM_NAME" -n "$NAD_NAMESPACE" 2>/dev/null || true
    print_ok "VM $VM_NAME 생성 완료 (eth0: masquerade, eth1: poc-bridge-nad)"
}

# =============================================================================
# 4단계: ConsoleYAMLSample 등록
# =============================================================================
step_consoleyamlsamples() {
    print_step "4/4  ConsoleYAMLSample 등록"

    cat > consoleyamlsample-nncp.yaml <<EOF
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: poc-bridge-nncp
spec:
  title: "POC Linux Bridge NNCP 생성"
  description: "워커 노드에 Linux Bridge(${BRIDGE_NAME})를 생성합니다. NMState Operator 설치 후 적용하세요. 인터페이스 이름(${BRIDGE_INTERFACE})을 환경에 맞게 수정하세요."
  targetResource:
    apiVersion: nmstate.io/v1
    kind: NodeNetworkConfigurationPolicy
  yaml: |
    apiVersion: nmstate.io/v1
    kind: NodeNetworkConfigurationPolicy
    metadata:
      name: poc-bridge-nncp
    spec:
      nodeSelector:
        node-role.kubernetes.io/worker: ""
      desiredState:
        interfaces:
          - name: ${BRIDGE_NAME}
            description: "POC VM용 Linux Bridge (${BRIDGE_INTERFACE} 기반)"
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
    echo "생성된 파일: consoleyamlsample-nncp.yaml"
    oc apply -f consoleyamlsample-nncp.yaml
    print_ok "ConsoleYAMLSample poc-bridge-nncp 등록 완료"

    cat > consoleyamlsample-nad.yaml <<EOF
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: poc-bridge-nad
spec:
  title: "POC Linux Bridge NAD 등록"
  description: "NNCP로 생성된 Linux Bridge(${BRIDGE_NAME})를 VM 보조 네트워크로 등록합니다. NNCP가 Available 상태인 후 적용하세요."
  targetResource:
    apiVersion: k8s.cni.cncf.io/v1
    kind: NetworkAttachmentDefinition
  yaml: |
    apiVersion: k8s.cni.cncf.io/v1
    kind: NetworkAttachmentDefinition
    metadata:
      name: poc-bridge-nad
      namespace: poc-vm-management
      annotations:
        k8s.v1.cni.cncf.io/resourceName: bridge.network.kubevirt.io/${BRIDGE_NAME}
    spec:
      config: '{"cniVersion":"0.3.1","name":"poc-bridge-nad","type":"cnv-bridge","bridge":"${BRIDGE_NAME}","macspoofchk":true,"ipam":{}}'
EOF
    echo "생성된 파일: consoleyamlsample-nad.yaml"
    oc apply -f consoleyamlsample-nad.yaml
    print_ok "ConsoleYAMLSample poc-bridge-nad 등록 완료"
}

# =============================================================================
# 완료 요약
# =============================================================================
print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  완료! NNCP + NAD 구성 및 VM 생성이 완료되었습니다.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  NNCP 상태 : ${CYAN}oc get nncp${NC}"
    echo -e "  NNCE 상태 : ${CYAN}oc get nnce${NC}"
    echo -e "  NAD 확인  : ${CYAN}oc get net-attach-def -n ${NAD_NAMESPACE}${NC}"
    echo -e "  VM 상태   : ${CYAN}oc get vm,vmi -n ${NAD_NAMESPACE}${NC}"
    echo ""
}

# =============================================================================
# 메인
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  네트워크 구성: NNCP + NAD + VM${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    preflight
    step_nncp
    step_nad
    step_vm
    step_consoleyamlsamples
    print_summary
}

main
