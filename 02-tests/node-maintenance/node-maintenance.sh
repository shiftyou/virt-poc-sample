#!/bin/bash
# =============================================================================
# 노드 유지보수 스크립트
# 노드 Cordon/Drain/Uncordon 및 Kubelet 중지/재시작을 관리합니다.
#
# 사용법:
#   ./node-maintenance.sh start <node-name>   # 유지보수 시작 (drain + kubelet stop)
#   ./node-maintenance.sh finish <node-name>  # 유지보수 종료 (kubelet start + uncordon)
#   ./node-maintenance.sh status <node-name>  # 노드 상태 확인
#   ./node-maintenance.sh drain <node-name>   # drain만 실행
#   ./node-maintenance.sh cordon <node-name>  # cordon만 실행
#   ./node-maintenance.sh uncordon <node-name> # uncordon만 실행
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../../env.conf"

if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
fi

ACTION="${1:-help}"
NODE="${2:-${TEST_NODE:-}}"

# 색상
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

usage() {
    echo "사용법: $0 <action> [node-name]"
    echo ""
    echo "Actions:"
    echo "  start   <node>  - 유지보수 시작 (cordon + drain + kubelet stop)"
    echo "  finish  <node>  - 유지보수 종료 (kubelet start + uncordon)"
    echo "  status  <node>  - 노드 상태 확인"
    echo "  drain   <node>  - 노드 drain만 실행"
    echo "  cordon  <node>  - 노드 cordon만 실행"
    echo "  uncordon <node> - 노드 uncordon만 실행"
    echo "  kubelet-stop  <node> - kubelet 중지"
    echo "  kubelet-start <node> - kubelet 시작"
    exit 1
}

check_node() {
    if [ -z "$NODE" ]; then
        echo -e "${RED}[ERROR]${NC} 노드 이름을 지정하세요."
        usage
    fi
    if ! oc get node "$NODE" &>/dev/null; then
        echo -e "${RED}[ERROR]${NC} 노드를 찾을 수 없습니다: $NODE"
        exit 1
    fi
}

show_status() {
    check_node
    echo -e "${GREEN}=== 노드 상태: ${NODE} ===${NC}"
    oc get node "$NODE"
    echo ""
    echo "--- 노드 리소스 ---"
    oc adm top node "$NODE" 2>/dev/null || echo "(metrics 없음)"
    echo ""
    echo "--- 노드의 Pod 수 ---"
    oc get pod -A --field-selector "spec.nodeName=${NODE}" \
        --no-headers 2>/dev/null | wc -l | xargs echo "총 Pod 수:"
    echo ""
    echo "--- VM 목록 ---"
    oc get vmi -A -o custom-columns="NAME:.metadata.name,NS:.metadata.namespace,NODE:.status.nodeName" \
        2>/dev/null | grep "$NODE" || echo "(VM 없음)"
}

do_cordon() {
    check_node
    echo -e "${YELLOW}[INFO]${NC} 노드 cordon 중: $NODE"
    oc adm cordon "$NODE"
    echo -e "${GREEN}[OK]${NC} 노드 cordon 완료: $NODE"
}

do_drain() {
    check_node
    echo -e "${YELLOW}[INFO]${NC} 노드 drain 중: $NODE"
    echo "  VM이 있으면 라이브 마이그레이션이 시작됩니다..."
    oc adm drain "$NODE" \
        --ignore-daemonsets \
        --delete-emptydir-data \
        --force \
        --timeout=300s
    echo -e "${GREEN}[OK]${NC} 노드 drain 완료: $NODE"
}

do_uncordon() {
    check_node
    echo -e "${YELLOW}[INFO]${NC} 노드 uncordon 중: $NODE"
    oc adm uncordon "$NODE"
    echo -e "${GREEN}[OK]${NC} 노드 uncordon 완료: $NODE"
    oc get node "$NODE"
}

do_kubelet_stop() {
    check_node
    echo -e "${YELLOW}[INFO]${NC} kubelet 중지 중: $NODE"
    oc debug "node/${NODE}" -- chroot /host systemctl stop kubelet
    echo -e "${GREEN}[OK]${NC} kubelet 중지 완료: $NODE"
}

do_kubelet_start() {
    check_node
    echo -e "${YELLOW}[INFO]${NC} kubelet 시작 중: $NODE"
    oc debug "node/${NODE}" -- chroot /host systemctl start kubelet
    sleep 5
    # kubelet 상태 확인
    oc debug "node/${NODE}" -- chroot /host systemctl is-active kubelet && \
        echo -e "${GREEN}[OK]${NC} kubelet 시작 완료: $NODE" || \
        echo -e "${RED}[WARN]${NC} kubelet 상태를 확인하세요."
}

case "$ACTION" in
    start)
        check_node
        echo -e "${YELLOW}[INFO]${NC} 노드 유지보수 시작: $NODE"
        do_cordon
        do_drain
        echo ""
        echo -e "${YELLOW}[INFO]${NC} kubelet을 중지하려면 다음 명령을 실행하세요:"
        echo "  $0 kubelet-stop $NODE"
        ;;
    finish)
        check_node
        echo -e "${YELLOW}[INFO]${NC} 노드 유지보수 종료: $NODE"
        do_kubelet_start
        do_uncordon
        show_status
        ;;
    status)
        show_status
        ;;
    drain)
        do_drain
        ;;
    cordon)
        do_cordon
        ;;
    uncordon)
        do_uncordon
        ;;
    kubelet-stop)
        do_kubelet_stop
        ;;
    kubelet-start)
        do_kubelet_start
        ;;
    *)
        usage
        ;;
esac
