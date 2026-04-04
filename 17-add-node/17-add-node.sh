#!/bin/bash
# =============================================================================
# 17-add-node.sh
#
# 워커 노드 제거 후 재조인 실습
#   1. 대상 노드 식별 (마지막 워커 노드)
#   2. Cordon + Drain (VM 포함)
#   3. kubelet 중지 → 노드 NotReady → 노드 오브젝트 삭제
#   4. kubelet 재시작 → CSR 승인 → 노드 재조인 확인
#   5. Uncordon + 최종 상태 검증
#
# 사용법: ./17-add-node.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

print_step()  { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }
print_ok()    { echo -e "  ${GREEN}✔ $1${NC}"; }
print_warn()  { echo -e "  ${YELLOW}⚠ $1${NC}"; }
print_info()  { echo -e "  ${BLUE}ℹ $1${NC}"; }
print_error() { echo -e "  ${RED}✘ $1${NC}"; }
print_cmd()   { echo -e "  ${CYAN}$ $1${NC}"; }

TARGET_NODE=""

# =============================================================================
preflight() {
    print_step "사전 확인"

    if ! oc whoami &>/dev/null; then
        print_error "OpenShift에 로그인되어 있지 않습니다."
        exit 1
    fi
    print_ok "클러스터 접속: $(oc whoami) @ $(oc whoami --show-server)"

    local worker_count
    worker_count=$(oc get nodes -l node-role.kubernetes.io/worker \
        --no-headers 2>/dev/null | wc -l | tr -d ' ')

    if [ "$worker_count" -lt 2 ]; then
        print_error "워커 노드가 2개 이상 필요합니다. (현재: ${worker_count}개)"
        print_info "노드를 제거하고 재조인하려면 나머지 워크로드를 수용할 노드가 있어야 합니다."
        exit 1
    fi
    print_ok "워커 노드 ${worker_count}개 확인"

    # 워커 노드 목록 표시 및 선택
    local workers
    mapfile -t workers < <(oc get nodes -l node-role.kubernetes.io/worker \
        --no-headers -o custom-columns=NAME:.metadata.name | sort)

    echo ""
    print_info "워커 노드 목록:"
    echo ""
    local idx=1
    for node in "${workers[@]}"; do
        local node_status
        node_status=$(oc get node "$node" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
        [ "$node_status" = "True" ] && node_status="${GREEN}Ready${NC}" || node_status="${YELLOW}NotReady${NC}"
        printf "    ${CYAN}[%d]${NC}  %-40s  " "$idx" "$node"
        echo -e "$node_status"
        idx=$((idx+1))
    done
    echo ""

    local choice
    read -r -p "  제거할 노드 번호를 선택하세요 [1-${#workers[@]}]: " choice

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#workers[@]}" ]; then
        print_error "잘못된 선택입니다: ${choice}"
        exit 1
    fi

    TARGET_NODE="${workers[$((choice-1))]}"
    print_ok "선택된 대상 노드: ${TARGET_NODE}"
}

# =============================================================================
step_identify() {
    print_step "1/5  노드 현황 확인"

    echo ""
    oc get nodes -o wide
    echo ""

    local node_ip
    node_ip=$(oc get node "$TARGET_NODE" \
        -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')

    print_info "대상 노드 : ${TARGET_NODE}"
    print_info "노드 IP   : ${node_ip}"
    print_info "SSH 접속  : ssh core@${node_ip}"
    echo ""
    print_warn "이 노드를 클러스터에서 제거한 뒤 kubelet 재시작으로 재조인시킵니다."
    echo ""
    read -r -p "  계속하시겠습니까? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "취소되었습니다."
        exit 0
    fi
}

# =============================================================================
step_drain() {
    print_step "2/5  Cordon + Drain (${TARGET_NODE})"

    print_info "노드를 Unschedulable 상태로 변경합니다..."
    oc adm cordon "$TARGET_NODE"
    print_ok "Cordon 완료"

    print_info "노드의 Pod/VM을 다른 노드로 이동합니다..."
    oc adm drain "$TARGET_NODE" \
        --delete-emptydir-data \
        --ignore-daemonsets \
        --force \
        --timeout=300s
    print_ok "Drain 완료"

    echo ""
    oc get nodes
}

# =============================================================================
step_stop_kubelet() {
    print_step "3/5  kubelet 중지 → 노드 오브젝트 삭제"

    local node_ip
    node_ip=$(oc get node "$TARGET_NODE" \
        -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')

    echo ""
    print_info "다음 명령을 노드에서 실행하여 kubelet을 중지하세요:"
    echo ""
    echo -e "  ${CYAN}ssh core@${node_ip}${NC}"
    echo -e "  ${CYAN}sudo systemctl stop kubelet${NC}"
    echo ""
    print_warn "kubelet을 중지하면 노드가 NotReady 상태로 전환됩니다."
    echo ""
    read -r -p "  kubelet을 중지했으면 Enter를 누르세요..."

    # NotReady 확인
    print_info "노드 상태가 NotReady로 전환되기를 기다립니다..."
    local retries=30
    local i=0
    while [ "$i" -lt "$retries" ]; do
        local status
        status=$(oc get node "$TARGET_NODE" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        if [ "$status" = "False" ] || [ "$status" = "Unknown" ]; then
            echo ""
            print_ok "노드 ${TARGET_NODE} → NotReady"
            break
        fi
        printf "  대기 중... (%d/%d)\r" "$((i+1))" "$retries"
        sleep 5
        i=$((i+1))
    done
    echo ""

    oc get nodes
    echo ""

    # 노드 오브젝트 삭제
    print_info "노드 오브젝트를 클러스터에서 삭제합니다..."
    oc delete node "$TARGET_NODE"
    print_ok "노드 오브젝트 삭제 완료 — 클러스터에서 제거됨"
    echo ""
    oc get nodes
}

# =============================================================================
step_start_kubelet() {
    print_step "4/5  kubelet 재시작 → 노드 재조인"

    local node_ip
    # 노드 오브젝트가 삭제됐으므로 이전에 저장된 IP 재사용
    node_ip=$(oc get node "$TARGET_NODE" \
        -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null \
        || echo "<node-ip>")

    echo ""
    print_info "다음 명령을 노드에서 실행하여 kubelet을 재시작하세요:"
    echo ""
    echo -e "  ${CYAN}ssh core@${node_ip:-<node-ip>}${NC}"
    echo -e "  ${CYAN}sudo systemctl start kubelet${NC}"
    echo ""
    print_info "kubelet이 시작되면 기존 인증서를 사용해 API 서버에 재등록합니다."
    print_info "CSR(인증서 서명 요청)이 생성되면 수동으로 승인해야 합니다."
    echo ""
    read -r -p "  kubelet을 시작했으면 Enter를 누르세요..."

    # CSR 수동 승인 안내 (최대 3분 대기)
    print_info "CSR 생성 및 노드 재조인 대기 중 (최대 3분)..."
    local retries=36
    local i=0
    local last_pending=""
    while [ "$i" -lt "$retries" ]; do
        local pending_csrs
        pending_csrs=$(oc get csr --no-headers 2>/dev/null \
            | awk '$4 ~ /Pending/ || $NF ~ /Pending/ {print $1}' \
            | tr '\n' ' ' | xargs || true)

        # 새로운 Pending CSR이 생긴 경우에만 안내 출력
        if [ -n "$pending_csrs" ] && [ "$pending_csrs" != "$last_pending" ]; then
            echo ""
            print_warn "승인 대기 중인 CSR이 있습니다:"
            echo ""
            oc get csr
            echo ""
            print_info "다음 명령으로 CSR을 승인하세요:"
            echo ""
            echo -e "  ${CYAN}oc adm certificate approve ${pending_csrs}${NC}"
            echo ""
            echo -e "  또는 Pending 전체 승인:"
            echo -e "  ${CYAN}oc get csr -o name | xargs oc adm certificate approve${NC}"
            echo ""
            read -r -p "  CSR 승인 후 Enter를 누르세요..."
            last_pending="$pending_csrs"
        fi

        # 노드가 Ready 상태인지 확인
        if oc get node "$TARGET_NODE" &>/dev/null; then
            local status
            status=$(oc get node "$TARGET_NODE" \
                -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
            if [ "$status" = "True" ]; then
                echo ""
                print_ok "노드 ${TARGET_NODE} → Ready"
                break
            fi
        fi

        printf "  노드 재조인 대기 중... (%d/%d)\r" "$((i+1))" "$retries"
        sleep 5
        i=$((i+1))
    done
    echo ""

    oc get nodes
}

# =============================================================================
step_verify() {
    print_step "5/5  Uncordon + 최종 검증"

    if oc get node "$TARGET_NODE" &>/dev/null; then
        oc adm uncordon "$TARGET_NODE"
        print_ok "Uncordon 완료 — 스케줄 가능 상태로 복원"
    else
        print_warn "노드가 아직 등록되지 않았습니다. 수동으로 uncordon이 필요할 수 있습니다:"
        print_cmd "oc adm uncordon ${TARGET_NODE}"
    fi

    echo ""
    oc get nodes -o wide
}

# =============================================================================
print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  완료! 노드 재조인 실습이 끝났습니다.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  최종 노드 상태:"
    echo -e "    ${CYAN}oc get nodes${NC}"
    echo ""
    echo -e "  CSR 상태 확인:"
    echo -e "    ${CYAN}oc get csr${NC}"
    echo ""
    echo -e "  자세한 내용: 16-add-node.md 참조"
    echo ""
}

# =============================================================================
main() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  16-add-node: 워커 노드 제거 후 재조인 실습${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    preflight
    step_identify
    step_drain
    step_stop_kubelet
    step_start_kubelet
    step_verify
    print_summary
}

main "$@"
