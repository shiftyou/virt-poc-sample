#!/bin/bash
# =============================================================================
# 03-vm-management.sh
#
# poc-vm-management 네임스페이스 생성 및 NAD 등록
# VM 워크로드 실행 환경을 준비합니다.
#
# 사용법: ./03-vm-management.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# env.conf 자동 로드 (단독 실행 시)
ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

VM_NS="poc-vm"
NNCP_NAME="${NNCP_NAME:-poc-bridge-nncp}"
BRIDGE_NAME="${BRIDGE_NAME}"
SECONDARY_IP_PREFIX="${SECONDARY_IP_PREFIX:-192.168.100}"

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

    # OpenShift Virtualization Operator 확인
    if [ "${VIRT_INSTALLED:-false}" != "true" ]; then
        print_warn "OpenShift Virtualization Operator 미설치 → 건너뜁니다."
        print_warn "  설치 가이드: 00-operator/kubevirt-hyperconverged-operator.md"
        exit 77
    fi

    print_ok "설정 확인"
    print_info "  VM_NS       : ${VM_NS}"
    print_info "  BRIDGE_NAME : ${BRIDGE_NAME}"

    if ! oc whoami &>/dev/null; then
        print_error "OpenShift 에 로그인되어 있지 않습니다."
        exit 1
    fi
    print_ok "클러스터 접속: $(oc whoami) @ $(oc whoami --show-server)"

    # NNCP / Bridge 확인
    if ! oc get nncp "$NNCP_NAME" &>/dev/null; then
        print_warn "NNCP '${NNCP_NAME}' 를 찾을 수 없습니다."
        # 현재 존재하는 NNCP 목록 표시 후 선택
        local _all_nncps
        _all_nncps=$(oc get nncp -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -v '^$' || true)
        if [ -n "$_all_nncps" ]; then
            print_info "현재 클러스터에 존재하는 NNCP 목록:"
            echo ""
            printf "    %-35s %-15s %-20s %s\n" "NNCP 이름" "타입" "Bridge 이름" "NIC"
            echo "    ────────────────────────────────────────────────────────────────────────"
            for _n in $_all_nncps; do
                local _b _nic _ob
                _b=$(oc get nncp "$_n" \
                    -o jsonpath='{range .spec.desiredState.interfaces[?(@.type=="linux-bridge")]}{.name}{end}' \
                    2>/dev/null || true)
                if [ -n "$_b" ]; then
                    _nic=$(oc get nncp "$_n" \
                        -o jsonpath='{range .spec.desiredState.interfaces[?(@.type=="linux-bridge")]}{.bridge.port[0].name}{end}' \
                        2>/dev/null || true)
                    printf "    %-35s %-15s %-20s %s\n" "$_n" "linux-bridge" "$_b" "${_nic:-N/A}"
                else
                    _ob=$(oc get nncp "$_n" \
                        -o jsonpath='{.spec.desiredState.ovn.bridge-mappings[0].bridge}' \
                        2>/dev/null || true)
                    if [ -n "$_ob" ]; then
                        printf "    %-35s %-15s %-20s %s\n" "$_n" "ovn-localnet" "$_ob" "-"
                    else
                        printf "    %-35s %-15s %-20s %s\n" "$_n" "unknown" "-" "-"
                    fi
                fi
            done
            echo ""
            local _first_nncp
            _first_nncp=$(echo "$_all_nncps" | head -1)
            read -r -p "  사용할 NNCP 이름을 입력하세요 [기본값: ${_first_nncp}]: " _input_nncp
            [ -z "$_input_nncp" ] && _input_nncp="$_first_nncp"
            NNCP_NAME="$_input_nncp"
            # 선택된 NNCP에서 bridge 이름 추출
            local _new_br
            _new_br=$(oc get nncp "$NNCP_NAME" \
                -o jsonpath='{range .spec.desiredState.interfaces[?(@.type=="linux-bridge")]}{.name}{end}' \
                2>/dev/null || true)
            [ -z "$_new_br" ] && _new_br=$(oc get nncp "$NNCP_NAME" \
                -o jsonpath='{.spec.desiredState.ovn.bridge-mappings[0].bridge}' \
                2>/dev/null || true)
            [ -n "$_new_br" ] && BRIDGE_NAME="$_new_br"
            print_ok "NNCP '${NNCP_NAME}' 사용 (bridge: ${BRIDGE_NAME})"
        else
            print_warn "사용 가능한 NNCP가 없습니다. 02-network 를 먼저 실행하세요."
        fi
    else
        local status
        status=$(oc get nncp "$NNCP_NAME" \
            -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)
        if [ "$status" = "True" ]; then
            print_ok "NNCP ${NNCP_NAME} Available"
        else
            print_warn "NNCP ${NNCP_NAME} 상태: ${status:-Unknown}"
        fi
    fi
}

# =============================================================================
# 1단계: 네임스페이스 생성
# =============================================================================
step_namespace() {
    print_step "1/3  네임스페이스 생성 (${VM_NS})"

    if oc get namespace "${VM_NS}" &>/dev/null; then
        print_ok "네임스페이스 ${VM_NS} 이미 존재합니다 — 스킵"
    else
        oc new-project "${VM_NS}" > /dev/null
        print_ok "네임스페이스 ${VM_NS} 생성 완료"
    fi
}

# spec.running(deprecated) → spec.runStrategy 마이그레이션
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
# 2단계: NAD 등록
# =============================================================================
step_nad() {
    print_step "2/4  NAD — NetworkAttachmentDefinition 등록 (${VM_NS})"

    cat > nad-vm-bridge.yaml <<EOF
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: poc-bridge-nad
  namespace: ${VM_NS}
  annotations:
    k8s.v1.cni.cncf.io/resourceName: bridge.network.kubevirt.io/${BRIDGE_NAME}
spec:
  config: '{"cniVersion":"0.3.1","name":"poc-bridge-nad","type":"cnv-bridge","bridge":"${BRIDGE_NAME}","macspoofchk":true,"ipam":{}}'
EOF
    echo "생성된 파일: nad-vm-bridge.yaml"
    oc apply -f nad-vm-bridge.yaml

    print_ok "NAD poc-bridge-nad 등록 완료 (namespace: ${VM_NS})"
}

# =============================================================================
# 3단계: VM 생성 (poc 템플릿 + poc-bridge-nad)
# =============================================================================
step_vm() {
    print_step "3/4  VM 생성 (poc 템플릿 + poc-bridge-nad)"

    if ! oc get template poc -n openshift &>/dev/null; then
        print_warn "poc Template 없음 — VM 생성을 건너뜁니다. (01-template 먼저 실행 필요)"
        return
    fi

    local VM_NAME="poc-vm"

    if oc get vm "$VM_NAME" -n "$VM_NS" &>/dev/null; then
        print_ok "VM $VM_NAME 이미 존재 — 스킵"
        return
    fi

    local vm_yaml="${SCRIPT_DIR}/vm-${VM_NAME}.yaml"
    oc process -n openshift poc -p NAME="$VM_NAME" | \
        sed 's/  running: false/  runStrategy: Halted/' > "${vm_yaml}"
    echo "생성된 파일: ${vm_yaml}"
    oc apply -n "$VM_NS" -f "${vm_yaml}"

    ensure_runstrategy "$VM_NAME" "$VM_NS"

    # 보조 NIC (poc-bridge-nad) 추가
    oc patch vm "$VM_NAME" -n "$VM_NS" --type=json -p='[
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

    # cloud-init networkData — eth1 정적 IP (03번 → .31/24)
    local ci_idx
    ci_idx=$(oc get vm "$VM_NAME" -n "$VM_NS" \
        -o jsonpath='{range .spec.template.spec.volumes[*]}{.name}{"\n"}{end}' 2>/dev/null | \
        grep -n "cloudinitdisk" | cut -d: -f1 | head -1)
    [ -n "$ci_idx" ] && ci_idx=$(( ci_idx - 1 ))

    if [ -n "$ci_idx" ]; then
        oc patch vm "$VM_NAME" -n "$VM_NS" --type=json -p="[
          {\"op\": \"add\",
           \"path\": \"/spec/template/spec/volumes/${ci_idx}/cloudInitNoCloud/networkData\",
           \"value\": \"version: 2\\nethernets:\\n  eth1:\\n    dhcp4: false\\n    addresses:\\n      - ${SECONDARY_IP_PREFIX}.31/24\\n    gateway4: ${SECONDARY_IP_PREFIX}.1\\n    nameservers:\\n      addresses:\\n        - 8.8.8.8\\n\"}
        ]"
        print_ok "networkData 추가 완료 (eth1: ${SECONDARY_IP_PREFIX}.31/24)"
    else
        print_warn "cloudinitdisk 볼륨을 찾지 못했습니다. networkData 미설정."
    fi

    virtctl start "$VM_NAME" -n "$VM_NS" 2>/dev/null || true
    print_ok "VM ${VM_NAME} 생성 완료 (eth0: masquerade, eth1: poc-bridge-nad, IP: ${SECONDARY_IP_PREFIX}.31/24)"
}

# =============================================================================
# 4단계: ConsoleYAMLSample 등록
# =============================================================================
step_consoleyamlsamples() {
    print_step "4/4  ConsoleYAMLSample 등록"

    cat > consoleyamlsample-virtualmachine.yaml <<EOF
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: poc-virtualmachine
spec:
  title: "POC VirtualMachine 생성 (Bridge 네트워크 + cloud-init 정적 IP)"
  description: "poc 템플릿 기반 VM에 Linux Bridge NAD(${BRIDGE_NAME})를 보조 네트워크로 연결하고, cloud-init으로 eth1 정적 IP를 설정합니다. poc Template 및 NAD 등록 후 적용하세요."
  targetResource:
    apiVersion: kubevirt.io/v1
    kind: VirtualMachine
  yaml: |
    apiVersion: kubevirt.io/v1
    kind: VirtualMachine
    metadata:
      name: poc-vm
      namespace: ${VM_NS}
    spec:
      runStrategy: Halted
      template:
        spec:
          domain:
            cpu:
              cores: 1
              sockets: 1
              threads: 1
            devices:
              disks:
                - disk:
                    bus: virtio
                  name: rootdisk
                - disk:
                    bus: virtio
                  name: cloudinitdisk
              interfaces:
                - masquerade: {}
                  model: virtio
                  name: default
                - bridge: {}
                  model: virtio
                  name: bridge-net
            memory:
              guest: 2Gi
          networks:
            - name: default
              pod: {}
            - name: bridge-net
              multus:
                networkName: poc-bridge-nad
          volumes:
            - dataVolume:
                name: poc-vm
              name: rootdisk
            - name: cloudinitdisk
              cloudInitNoCloud:
                userData: |-
                  #cloud-config
                  user: cloud-user
                  password: changeme
                  chpasswd: { expire: False }
                networkData: |
                  version: 2
                  ethernets:
                    eth1:
                      dhcp4: false
                      addresses:
                        - ${SECONDARY_IP_PREFIX}.10/24
                      gateway4: ${SECONDARY_IP_PREFIX}.1
                      nameservers:
                        addresses:
                          - 8.8.8.8
      dataVolumeTemplates:
        - metadata:
            name: poc-vm
          spec:
            sourceRef:
              kind: DataSource
              name: poc
              namespace: openshift-virtualization-os-images
            storage:
              resources:
                requests:
                  storage: 30Gi
EOF
    echo "생성된 파일: consoleyamlsample-virtualmachine.yaml"
    oc apply -f consoleyamlsample-virtualmachine.yaml
    print_ok "ConsoleYAMLSample poc-virtualmachine 등록 완료"
}

# =============================================================================
# 완료 요약
# =============================================================================
print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  완료! VM 워크로드 환경이 준비되었습니다.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  네임스페이스 : ${CYAN}oc get namespace ${VM_NS}${NC}"
    echo -e "  NAD 확인    : ${CYAN}oc get net-attach-def -n ${VM_NS}${NC}"
    echo ""
    echo -e "  다음 단계: 03-vm-management.md 를 참조하세요"
    echo -e "    - poc 템플릿을 이용한 VM 생성"
    echo -e "    - 스토리지 추가"
    echo -e "    - 네트워크 추가"
    echo -e "    - Static IP / Domain / Router 설정"
    echo -e "    - Live Migration"
    echo ""
}

# =============================================================================
# 메인
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  VM 관리 환경 준비: 네임스페이스 + NAD${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    preflight
    step_namespace
    step_nad
    step_vm
    step_consoleyamlsamples
    print_summary
}

main
