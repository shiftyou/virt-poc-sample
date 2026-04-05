#!/bin/bash
# =============================================================================
# 05-network-policy.sh
#
# NetworkPolicy / MultiNetworkPolicy 실습 환경 구성
#
#   1. NetworkPolicy (Linux Bridge)
#      - 네임스페이스: poc-network-policy-1, poc-network-policy-2
#      - NAD: cnv-bridge (Linux Bridge)
#      - 정책: networking.k8s.io/v1 NetworkPolicy (pod network / eth0)
#
#   2. MultiNetworkPolicy (OVN Localnet)
#      - 네임스페이스: poc-multi-network-policy-1, poc-multi-network-policy-2
#      - NAD: ovn-k8s-cni-overlay (OVN Localnet)
#      - 정책: k8s.cni.cncf.io/v1beta1 MultiNetworkPolicy (secondary NIC / eth1)
#
# 사용법: ./05-network-policy.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

BRIDGE_NAME="${BRIDGE_NAME:-br1}"
OVN_LOCALNET_NAME="poc-localnet"
SECONDARY_IP_PREFIX="${SECONDARY_IP_PREFIX:-192.168.100}"

# 모드별로 설정되는 변수
POLICY_MODE=""
NS1=""
NS2=""
NAD_NAME=""
TOTAL_STEPS=6

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
# 모드 선택
# =============================================================================
choose_mode() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  네트워크 정책 방식을 선택하세요${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${GREEN}1)${NC} NetworkPolicy  (Linux Bridge)"
    echo -e "     ${CYAN}networking.k8s.io/v1${NC} NetworkPolicy"
    echo -e "     pod network(eth0) 트래픽 제어"
    echo -e "     secondary NIC(eth1, Linux Bridge)은 정책 적용 대상 외"
    echo -e "     네임스페이스: poc-network-policy-1, poc-network-policy-2"
    echo ""
    echo -e "  ${GREEN}2)${NC} MultiNetworkPolicy  (OVN Localnet)"
    echo -e "     ${CYAN}k8s.cni.cncf.io/v1beta1${NC} MultiNetworkPolicy"
    echo -e "     secondary NIC(eth1, OVN Localnet) 트래픽 직접 제어"
    echo -e "     02-network에서 OVN Localnet(방식 2/4) 구성 필요"
    echo -e "     네임스페이스: poc-multi-network-policy-1, poc-multi-network-policy-2"
    echo ""
    read -r -p "  선택 [1-2]: " POLICY_MODE

    case "$POLICY_MODE" in
        1)
            NS1="poc-network-policy-1"
            NS2="poc-network-policy-2"
            NAD_NAME="poc-bridge-nad"
            TOTAL_STEPS=6
            print_ok "선택: NetworkPolicy (Linux Bridge)"
            ;;
        2)
            NS1="poc-multi-network-policy-1"
            NS2="poc-multi-network-policy-2"
            NAD_NAME="poc-localnet-nad"
            TOTAL_STEPS=8
            print_ok "선택: MultiNetworkPolicy (OVN Localnet)"
            ;;
        *)
            print_error "1 또는 2를 입력하세요."
            exit 1
            ;;
    esac
}

# =============================================================================
# 사전 확인
# =============================================================================
preflight() {
    print_step "사전 확인"

    if [ "${VIRT_INSTALLED:-false}" != "true" ]; then
        print_warn "OpenShift Virtualization Operator 미설치 → 건너뜁니다."
        exit 77
    fi

    if ! oc whoami &>/dev/null; then
        print_error "OpenShift에 로그인되어 있지 않습니다."
        exit 1
    fi
    print_ok "클러스터 접속: $(oc whoami) @ $(oc whoami --show-server)"

    if ! oc get template poc -n openshift &>/dev/null; then
        print_error "poc Template이 없습니다. 01-template을 먼저 실행하세요."
        exit 1
    fi
    print_ok "poc Template 확인"

    print_info "  NS1        : ${NS1}"
    print_info "  NS2        : ${NS2}"
    print_info "  NAD        : ${NAD_NAME}"

    if [ "$POLICY_MODE" = "2" ]; then
        # OVN Localnet NNCP 존재 여부 확인
        if ! oc get nncp poc-localnet-nncp &>/dev/null; then
            print_warn "poc-localnet-nncp NNCP가 없습니다."
            print_warn "  02-network를 방식 2(OVN Localnet) 또는 4(OVN Localnet + VLAN)로 먼저 실행하세요."
            exit 1
        fi
        print_ok "OVN Localnet NNCP (poc-localnet-nncp) 확인"

        # MultiNetworkPolicy 활성화 확인
        local mnp_enabled
        mnp_enabled=$(oc get network.operator.openshift.io cluster \
            -o jsonpath='{.spec.useMultiNetworkPolicy}' 2>/dev/null || echo "false")
        if [ "$mnp_enabled" != "true" ]; then
            print_warn "MultiNetworkPolicy가 비활성화되어 있습니다. 활성화합니다..."
            oc patch network.operator.openshift.io cluster --type=merge \
                -p '{"spec":{"useMultiNetworkPolicy":true}}'
            print_ok "MultiNetworkPolicy 활성화 완료 (네트워크 오퍼레이터 재구성까지 1~2분 소요)"
        else
            print_ok "MultiNetworkPolicy 활성화 확인"
        fi
    fi
}

# =============================================================================
# 1단계: (MultiNetworkPolicy 전용) 활성화 대기
# =============================================================================
step_wait_mnp() {
    print_step "1/${TOTAL_STEPS}  MultiNetworkPolicy 오퍼레이터 준비 대기"

    print_info "네트워크 오퍼레이터 재구성 대기 중 (최대 2분)..."
    local retries=24 i=0
    while [ "$i" -lt "$retries" ]; do
        local progressing
        progressing=$(oc get network.operator.openshift.io cluster \
            -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null || echo "")
        if [ "$progressing" = "False" ]; then
            print_ok "네트워크 오퍼레이터 준비 완료"
            return
        fi
        printf "  [%d/%d] 재구성 중...\r" "$((i+1))" "$retries"
        sleep 5
        i=$((i+1))
    done
    echo ""
    print_warn "대기 시간 초과. 계속 진행하지만 MultiNetworkPolicy가 즉시 동작하지 않을 수 있습니다."
}

# =============================================================================
# 네임스페이스 단계 번호 계산
# =============================================================================
_snum() {
    # POLICY_MODE=1: 1/6, POLICY_MODE=2: 2/7
    if [ "$POLICY_MODE" = "1" ]; then echo "1"; else echo "2"; fi
}

# =============================================================================
# 네임스페이스 생성
# =============================================================================
step_namespaces() {
    print_step "$(_snum)/${TOTAL_STEPS}  네임스페이스 생성"

    for NS in "$NS1" "$NS2"; do
        if oc get namespace "$NS" &>/dev/null; then
            print_ok "네임스페이스 $NS 이미 존재 — 스킵"
        else
            oc new-project "$NS" > /dev/null
            print_ok "네임스페이스 $NS 생성 완료"
        fi
    done
}

# =============================================================================
# NAD 등록
# =============================================================================
step_nad() {
    local step=$(( $(_snum) + 1 ))
    print_step "${step}/${TOTAL_STEPS}  NAD 등록 (${NAD_NAME})"

    for NS in "$NS1" "$NS2"; do
        if [ "$POLICY_MODE" = "1" ]; then
            cat > "nad-${NS}.yaml" <<EOF
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: ${NAD_NAME}
  namespace: ${NS}
  annotations:
    k8s.v1.cni.cncf.io/resourceName: bridge.network.kubevirt.io/${BRIDGE_NAME}
spec:
  config: |-
    {
        "cniVersion": "0.3.1",
        "name": "${NAD_NAME}",
        "type": "bridge",
        "bridge": "${BRIDGE_NAME}",
        "ipam": {},
        "macspoofchk": true,
        "preserveDefaultVlan": false
    }
EOF
        else
            cat > "nad-${NS}.yaml" <<EOF
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: ${NAD_NAME}
  namespace: ${NS}
spec:
  config: '{"cniVersion":"0.3.1","name":"${OVN_LOCALNET_NAME}","type":"ovn-k8s-cni-overlay","topology":"localnet","netAttachDefName":"${NS}/${NAD_NAME}"}'
EOF
        fi
        echo "생성된 파일: nad-${NS}.yaml"
        oc apply -f "nad-${NS}.yaml"
        print_ok "NAD 등록 완료 (namespace: ${NS})"
    done
}

# =============================================================================
# Default Deny All 정책
# =============================================================================
step_deny_all() {
    local step=$(( $(_snum) + 2 ))
    print_step "${step}/${TOTAL_STEPS}  Default Deny All 정책 적용"

    for NS in "$NS1" "$NS2"; do
        if [ "$POLICY_MODE" = "1" ]; then
            cat > "netpol-deny-all-${NS}.yaml" <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: ${NS}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
EOF
        else
            cat > "netpol-deny-all-${NS}.yaml" <<EOF
apiVersion: k8s.cni.cncf.io/v1beta1
kind: MultiNetworkPolicy
metadata:
  name: default-deny-all
  namespace: ${NS}
  annotations:
    k8s.v1.cni.cncf.io/policy-for: ${NS}/${NAD_NAME}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
EOF
        fi
        echo "생성된 파일: netpol-deny-all-${NS}.yaml"
        oc apply -f "netpol-deny-all-${NS}.yaml"
        print_ok "Deny All 적용 완료 (namespace: ${NS})"
    done
}

# =============================================================================
# Allow Same Namespace 정책
# =============================================================================
step_allow_same_ns() {
    local step=$(( $(_snum) + 3 ))
    print_step "${step}/${TOTAL_STEPS}  Allow Same Namespace 정책 적용"

    for NS in "$NS1" "$NS2"; do
        if [ "$POLICY_MODE" = "1" ]; then
            cat > "netpol-allow-same-ns-${NS}.yaml" <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-same-namespace
  namespace: ${NS}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - podSelector: {}
  egress:
    - to:
        - podSelector: {}
EOF
        else
            cat > "netpol-allow-same-ns-${NS}.yaml" <<EOF
apiVersion: k8s.cni.cncf.io/v1beta1
kind: MultiNetworkPolicy
metadata:
  name: allow-same-namespace
  namespace: ${NS}
  annotations:
    k8s.v1.cni.cncf.io/policy-for: ${NS}/${NAD_NAME}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - podSelector: {}
  egress:
    - to:
        - podSelector: {}
EOF
        fi
        echo "생성된 파일: netpol-allow-same-ns-${NS}.yaml"
        oc apply -f "netpol-allow-same-ns-${NS}.yaml"
        print_ok "Allow Same Namespace 적용 완료 (namespace: ${NS})"
    done
}

# =============================================================================
# VM 배포
# =============================================================================
step_vms() {
    local step=$(( $(_snum) + 4 ))
    print_step "${step}/${TOTAL_STEPS}  VM 배포 (poc 템플릿 + ${NAD_NAME})"

    for NS in "$NS1" "$NS2"; do
        local suffix
        suffix=$(echo "$NS" | awk -F'-' '{print $NF}')
        local VM_NAME="poc-vm-${suffix}"

        if oc get vm "$VM_NAME" -n "$NS" &>/dev/null; then
            print_ok "VM $VM_NAME 이미 존재 (namespace: $NS) — 스킵"
            continue
        fi

        oc process -n openshift poc -p NAME="$VM_NAME" | \
            sed 's/runStrategy: Always/runStrategy: Halted/' | sed 's/  running: false/  runStrategy: Halted/' > "${VM_NAME}-${NS}.yaml"
        echo "생성된 파일: ${VM_NAME}-${NS}.yaml"
        oc apply -n "$NS" -f "${VM_NAME}-${NS}.yaml"

        # secondary NIC (NAD) 추가
        oc patch vm "$VM_NAME" -n "$NS" --type=json -p='[
          {
            "op": "add",
            "path": "/spec/template/spec/domain/devices/interfaces/-",
            "value": {"name": "secondary", "bridge": {}, "model": "virtio"}
          },
          {
            "op": "add",
            "path": "/spec/template/spec/networks/-",
            "value": {"name": "secondary", "multus": {"networkName": "'"${NAD_NAME}"'"}}
          }
        ]'

        # cloud-init networkData — 기존 cloudinitdisk 볼륨에 networkData 추가 (VM 시작 전)
        # NS1 → .51/24, NS2 → .52/24
        local ip_suffix
        if [ "$NS" = "$NS1" ]; then ip_suffix="51"; else ip_suffix="52"; fi

        local ci_idx
        ci_idx=$(oc get vm "$VM_NAME" -n "$NS" \
            -o jsonpath='{range .spec.template.spec.volumes[*]}{.name}{"\n"}{end}' 2>/dev/null | \
            grep -n "cloudinitdisk" | cut -d: -f1 | head -1)
        # grep -n은 1-based, JSON patch는 0-based
        [ -n "$ci_idx" ] && ci_idx=$(( ci_idx - 1 ))

        if [ -n "$ci_idx" ]; then
            oc patch vm "$VM_NAME" -n "$NS" --type=json -p="[
              {\"op\": \"add\",
               \"path\": \"/spec/template/spec/volumes/${ci_idx}/cloudInitNoCloud/networkData\",
               \"value\": \"version: 2\\nethernets:\\n  eth1:\\n    dhcp4: false\\n    addresses:\\n      - ${SECONDARY_IP_PREFIX}.${ip_suffix}/24\\n    gateway4: ${SECONDARY_IP_PREFIX}.1\\n    nameservers:\\n      addresses:\\n        - 8.8.8.8\\n\"}
            ]"
            print_ok "networkData 추가 완료 → cloudinitdisk (index: ${ci_idx})"
        else
            print_warn "cloudinitdisk 볼륨을 찾지 못했습니다. networkData 미설정."
        fi

        virtctl start "$VM_NAME" -n "$NS" 2>/dev/null || true
        print_ok "VM $VM_NAME 배포 완료 (namespace: $NS, eth1: ${NAD_NAME}, IP: ${SECONDARY_IP_PREFIX}.${ip_suffix}/24)"
    done
}

# =============================================================================
# ConsoleYAMLSample 등록
# =============================================================================
step_consoleyamlsamples() {
    local step=$(( $(_snum) + 5 ))
    print_step "${step}/${TOTAL_STEPS}  ConsoleYAMLSample 등록"

    local api_ver kind suffix
    if [ "$POLICY_MODE" = "1" ]; then
        api_ver="networking.k8s.io/v1"
        kind="NetworkPolicy"
        suffix="netpol"
    else
        api_ver="k8s.cni.cncf.io/v1beta1"
        kind="MultiNetworkPolicy"
        suffix="multi-netpol"
    fi

    # Deny All 샘플
    local deny_yaml
    if [ "$POLICY_MODE" = "1" ]; then
        deny_yaml="$(cat <<YAML
    apiVersion: networking.k8s.io/v1
    kind: NetworkPolicy
    metadata:
      name: default-deny-all
      namespace: ${NS1}
    spec:
      podSelector: {}
      policyTypes:
        - Ingress
        - Egress
YAML
)"
    else
        deny_yaml="$(cat <<YAML
    apiVersion: k8s.cni.cncf.io/v1beta1
    kind: MultiNetworkPolicy
    metadata:
      name: default-deny-all
      namespace: ${NS1}
      annotations:
        k8s.v1.cni.cncf.io/policy-for: ${NS1}/${NAD_NAME}
    spec:
      podSelector: {}
      policyTypes:
        - Ingress
        - Egress
YAML
)"
    fi

    cat > consoleyamlsample-deny-all.yaml <<EOF
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: poc-${suffix}-deny-all
spec:
  title: "POC ${kind} — Default Deny All"
  description: "네임스페이스의 모든 Ingress/Egress를 차단합니다."
  targetResource:
    apiVersion: ${api_ver}
    kind: ${kind}
  yaml: |
${deny_yaml}
EOF
    echo "생성된 파일: consoleyamlsample-deny-all.yaml"
    oc apply -f consoleyamlsample-deny-all.yaml
    print_ok "ConsoleYAMLSample poc-${suffix}-deny-all 등록"

    # Allow Same NS 샘플
    local allow_yaml
    if [ "$POLICY_MODE" = "1" ]; then
        allow_yaml="$(cat <<YAML
    apiVersion: networking.k8s.io/v1
    kind: NetworkPolicy
    metadata:
      name: allow-same-namespace
      namespace: ${NS1}
    spec:
      podSelector: {}
      policyTypes:
        - Ingress
        - Egress
      ingress:
        - from:
            - podSelector: {}
      egress:
        - to:
            - podSelector: {}
YAML
)"
    else
        allow_yaml="$(cat <<YAML
    apiVersion: k8s.cni.cncf.io/v1beta1
    kind: MultiNetworkPolicy
    metadata:
      name: allow-same-namespace
      namespace: ${NS1}
      annotations:
        k8s.v1.cni.cncf.io/policy-for: ${NS1}/${NAD_NAME}
    spec:
      podSelector: {}
      policyTypes:
        - Ingress
        - Egress
      ingress:
        - from:
            - podSelector: {}
      egress:
        - to:
            - podSelector: {}
YAML
)"
    fi

    cat > consoleyamlsample-allow-same-ns.yaml <<EOF
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: poc-${suffix}-allow-same-ns
spec:
  title: "POC ${kind} — Allow Same Namespace"
  description: "같은 네임스페이스 내 Pod 간 통신을 허용합니다."
  targetResource:
    apiVersion: ${api_ver}
    kind: ${kind}
  yaml: |
${allow_yaml}
EOF
    echo "생성된 파일: consoleyamlsample-allow-same-ns.yaml"
    oc apply -f consoleyamlsample-allow-same-ns.yaml
    print_ok "ConsoleYAMLSample poc-${suffix}-allow-same-ns 등록"

    # Mode 1: NetworkPolicy — VM IP는 VMI 기동 후 확인 가능하므로 참고용 파일만 생성
    if [ "$POLICY_MODE" = "1" ]; then
        cat > netpol-allow-from-ns1-ip.yaml <<EOF
# =============================================================================
# [NetworkPolicy] ${NS2} — NS1 VM IP 허용
#
# ${NS1} VM IP 확인:
#   oc get vmi -n ${NS1} \\
#     -o jsonpath='{.items[0].status.interfaces[0].ipAddress}'
#
# IP 수정 후 적용:
#   oc apply -f netpol-allow-from-ns1-ip.yaml
# =============================================================================
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-from-ns1-vm-ip
  namespace: ${NS2}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - ipBlock:
            cidr: 192.168.0.1/32    # ← ${NS1} VM IP로 교체
EOF
        echo "생성된 파일: netpol-allow-from-ns1-ip.yaml"
        print_ok "netpol-allow-from-ns1-ip.yaml 생성 완료 (IP 수정 후 수동 적용)"
    fi
}

# =============================================================================
# 크로스 네임스페이스 허용 (MultiNetworkPolicy 전용)
# NS1 VM(secondary .51) ↔ NS2 VM(secondary .52) 양방향 통신 허용
# =============================================================================
step_allow_cross_ns() {
    [ "$POLICY_MODE" != "2" ] && return 0

    local step=$(( $(_snum) + 4 ))
    print_step "${step}/${TOTAL_STEPS}  크로스 네임스페이스 허용 (${NS1} ↔ ${NS2})"

    local ip_ns1="${SECONDARY_IP_PREFIX}.51"
    local ip_ns2="${SECONDARY_IP_PREFIX}.52"

    # NS1: NS2 VM IP 허용 (Ingress + Egress)
    cat > "multi-netpol-allow-cross-ns-${NS1}.yaml" <<EOF
apiVersion: k8s.cni.cncf.io/v1beta1
kind: MultiNetworkPolicy
metadata:
  name: allow-cross-namespace
  namespace: ${NS1}
  annotations:
    k8s.v1.cni.cncf.io/policy-for: ${NS1}/${NAD_NAME}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - ipBlock:
            cidr: ${ip_ns2}/32
  egress:
    - to:
        - ipBlock:
            cidr: ${ip_ns2}/32
EOF
    echo "생성된 파일: multi-netpol-allow-cross-ns-${NS1}.yaml"
    oc apply -f "multi-netpol-allow-cross-ns-${NS1}.yaml"
    print_ok "allow-cross-namespace 적용 완료 (namespace: ${NS1}, 허용 대상: ${ip_ns2})"

    # NS2: NS1 VM IP 허용 (Ingress + Egress)
    cat > "multi-netpol-allow-cross-ns-${NS2}.yaml" <<EOF
apiVersion: k8s.cni.cncf.io/v1beta1
kind: MultiNetworkPolicy
metadata:
  name: allow-cross-namespace
  namespace: ${NS2}
  annotations:
    k8s.v1.cni.cncf.io/policy-for: ${NS2}/${NAD_NAME}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - ipBlock:
            cidr: ${ip_ns1}/32
  egress:
    - to:
        - ipBlock:
            cidr: ${ip_ns1}/32
EOF
    echo "생성된 파일: multi-netpol-allow-cross-ns-${NS2}.yaml"
    oc apply -f "multi-netpol-allow-cross-ns-${NS2}.yaml"
    print_ok "allow-cross-namespace 적용 완료 (namespace: ${NS2}, 허용 대상: ${ip_ns1})"
}

# =============================================================================
# 완료 요약
# =============================================================================
print_summary() {
    local policy_kind
    [ "$POLICY_MODE" = "1" ] && policy_kind="NetworkPolicy" || policy_kind="MultiNetworkPolicy"

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  완료! ${policy_kind} 실습 환경이 준비되었습니다.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  정책 확인:"
    if [ "$POLICY_MODE" = "1" ]; then
        echo -e "    ${CYAN}oc get networkpolicy -n ${NS1}${NC}"
        echo -e "    ${CYAN}oc get networkpolicy -n ${NS2}${NC}"
    else
        echo -e "    ${CYAN}oc get multinetworkpolicy -n ${NS1}${NC}"
        echo -e "    ${CYAN}oc get multinetworkpolicy -n ${NS2}${NC}"
    fi
    echo ""
    echo -e "  VM 상태 확인:"
    echo -e "    ${CYAN}oc get vmi -n ${NS1}${NC}"
    echo -e "    ${CYAN}oc get vmi -n ${NS2}${NC}"
    echo ""
    echo -e "  다음 단계: 05-network-policy.md 참조"
    if [ "$POLICY_MODE" = "1" ]; then
        echo -e "    1. VM IP 확인 후 netpol-allow-from-ns1-ip.yaml 수정 → 적용"
        echo -e "    2. VM 콘솔에서 ping/curl 통신 테스트"
    else
        echo -e "  적용된 MultiNetworkPolicy:"
        echo -e "    - default-deny-all     : secondary NIC 전체 차단"
        echo -e "    - allow-same-namespace : 같은 네임스페이스 내 통신 허용"
        echo -e "    - allow-cross-namespace: ${NS1} ↔ ${NS2} 양방향 허용"
        echo -e "    1. VM 콘솔에서 ping ${SECONDARY_IP_PREFIX}.52 (NS1→NS2) 테스트"
        echo -e "    2. VM 콘솔에서 ping ${SECONDARY_IP_PREFIX}.51 (NS2→NS1) 테스트"
    fi
    echo ""
}

# =============================================================================
# 메인
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  04-network-policy: NetworkPolicy / MultiNetworkPolicy 실습${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    choose_mode
    preflight

    if [ "$POLICY_MODE" = "2" ]; then
        step_wait_mnp
    fi

    step_namespaces
    step_nad
    step_deny_all
    step_allow_same_ns
    step_allow_cross_ns
    step_vms
    step_consoleyamlsamples
    print_summary
}

main
