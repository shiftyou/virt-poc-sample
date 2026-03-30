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

VM_NS="poc-vm-management"
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
    if ! oc get nncp poc-bridge-nncp &>/dev/null; then
        print_warn "NNCP poc-bridge-nncp 를 찾을 수 없습니다. 02-network 를 먼저 실행하세요."
    else
        local status
        status=$(oc get nncp poc-bridge-nncp \
            -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)
        if [ "$status" = "True" ]; then
            print_ok "NNCP poc-bridge-nncp Available"
        else
            print_warn "NNCP poc-bridge-nncp 상태: ${status:-Unknown}"
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

# =============================================================================
# 2단계: NAD 등록
# =============================================================================
step_nad() {
    print_step "2/3  NAD — NetworkAttachmentDefinition 등록 (${VM_NS})"

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
# 3단계: ConsoleYAMLSample 등록
# =============================================================================
step_consoleyamlsamples() {
    print_step "3/3  ConsoleYAMLSample 등록"

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
                  name: cloudinit
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
            - name: cloudinit
              cloudInitNoCloud:
                networkData: |
                  version: 2
                  ethernets:
                    eth1:
                      dhcp4: false
                      addresses:
                        - ${SECONDARY_IP_PREFIX}.10/24
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
    step_consoleyamlsamples
    print_summary
}

main
