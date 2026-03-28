#!/bin/bash
# =============================================================================
# make.sh
#
# 번호 순 디렉토리(01-, 02-, ...)의 .sh를 순서대로 실행합니다.
# setup.sh 를 먼저 실행하여 env.conf 를 생성하세요.
#   예) 01-template/01-template.sh
#       02-network/02-network.sh
#       03-vm-management/03-vm-management.sh
#
# 사용법: ./make.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/env.conf"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
DIM='\033[2m'
NC='\033[0m'

print_info()  { echo -e "${CYAN}[make]${NC} $1"; }
print_ok()    { echo -e "${GREEN}[make]${NC} $1"; }
print_error() { echo -e "${RED}[make]${NC} $1"; }

# env.conf 확인 및 로드
if [ ! -f "$ENV_FILE" ]; then
    print_error "env.conf 가 없습니다. 먼저 setup.sh 를 실행하세요."
    exit 1
fi

set -a
source "$ENV_FILE"
set +a

POC_SETUP_DIR="${SCRIPT_DIR}/poc-setup"

# 번호 디렉토리를 정렬해서 수집
STEPS=()
while IFS= read -r dir; do
    STEPS+=("$(basename "$dir")")
done < <(find "$SCRIPT_DIR" -maxdepth 1 -type d -name '[0-9][0-9]-*' | sort)

if [ ${#STEPS[@]} -eq 0 ]; then
    print_error "실행할 단계가 없습니다. 01-, 02-... 디렉토리 없음"
    exit 1
fi

TOTAL=${#STEPS[@]}

# 각 스텝 상태 배열 (인덱스 대응): pending / ok / skip / fail
STEP_RESULTS=()
for i in $(seq 0 $((TOTAL - 1))); do
    STEP_RESULTS+=("pending")
done

# 스텝 설명
step_desc() {
    case "$1" in
        01-template)        echo "DataVolume 업로드 → DataSource → Template 등록" ;;
        02-network)         echo "NNCP Linux Bridge + NAD + VM 생성" ;;
        03-vm-management)   echo "네임스페이스 + NAD 준비" ;;
        04-network-policy)  echo "NetworkPolicy — Deny All / Allow Same NS / Allow IP" ;;
        05-resource-quota)  echo "ResourceQuota — CPU·Memory·Pod·PVC 제한" ;;
        06-descheduler)     echo "Descheduler — VM 자동 재배치 (Operator 필요)" ;;
        07-node-maintenance) echo "Node Maintenance — 노드 유지보수 VM Migration (Operator 필요)" ;;
        08-snr)             echo "SNR — 노드 자가 재시작 복구 (Operator 필요)" ;;
        09-far)             echo "FAR — IPMI/BMC 전원 재시작 복구 (Operator 필요)" ;;
        10-liveness-probe)  echo "VM Liveness Probe — HTTP·TCP·Exec" ;;
        11-alert)           echo "VM Alert — PrometheusRule 알림" ;;
        12-node-exporter)   echo "Node Exporter — 커스텀 메트릭 수집" ;;
        13-monitoring)      echo "Grafana 모니터링 (Operator 필요)" ;;
        14-oadp)            echo "OADP — VM 백업/복원 (Operator 필요)" ;;
        15-hyperconverged)  echo "HyperConverged — CPU Overcommit 설정" ;;
        16-mtv)             echo "MTV — VMware → OpenShift 마이그레이션 (Operator 필요)" ;;
        *)                  echo "$1" ;;
    esac
}

# 진행 상황 테이블 출력
print_progress() {
    local completed=0 skipped=0 failed=0
    for r in "${STEP_RESULTS[@]}"; do
        case "$r" in
            ok)   completed=$((completed+1)) ;;
            skip) skipped=$((skipped+1)) ;;
            fail) failed=$((failed+1)) ;;
        esac
    done

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    printf "${CYAN}  진행 상황  완료:%-3d 건너뜀:%-3d 실패:%-3d / 전체:%-3d${NC}\n" \
        "$completed" "$skipped" "$failed" "$TOTAL"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    printf "  %-28s %s\n" "Step" "Status"
    echo "  ──────────────────────────────────────────────────────────"

    local i=0
    for dir in "${STEPS[@]}"; do
        local result="${STEP_RESULTS[$i]}"
        local desc
        desc=$(step_desc "$dir")
        case "$result" in
            ok)
                printf "  ${GREEN}[✔]${NC} %-26s ${GREEN}→ 완료${NC}  ${DIM}%s${NC}\n" \
                    "$dir" "$desc"
                ;;
            skip)
                printf "  ${YELLOW}[~]${NC} %-26s ${YELLOW}→ 건너뜀${NC}  ${DIM}%s${NC}\n" \
                    "$dir" "$desc"
                ;;
            fail)
                printf "  ${RED}[✘]${NC} %-26s ${RED}→ 실패${NC}  ${DIM}%s${NC}\n" \
                    "$dir" "$desc"
                ;;
            pending)
                printf "  ${DIM}[·] %-26s   대기 중  %s${NC}\n" \
                    "$dir" "$desc"
                ;;
        esac
        i=$((i+1))
    done
    echo "  ──────────────────────────────────────────────────────────"
    echo ""
}

# 시작 헤더
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  virt-poc-sample 전체 실행 (총 ${TOTAL}단계)${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# 초기 상태 테이블 출력
print_progress

# 순서대로 실행
IDX=0
for dir in "${STEPS[@]}"; do
    SH_FILE="${SCRIPT_DIR}/${dir}/${dir}.sh"

    echo ""
    IDX=$((IDX + 1))
    echo -e "${CYAN}━━━ [${IDX}/${TOTAL}] ${dir} ━━━${NC}"

    if [ ! -f "$SH_FILE" ]; then
        print_error "스크립트를 찾을 수 없습니다: ${dir}/${dir}.sh — 건너뜁니다"
        STEP_RESULTS[$((IDX-1))]="skip"
        print_progress
        continue
    fi

    OUT_DIR="${POC_SETUP_DIR}/${dir}"
    mkdir -p "$OUT_DIR"

    print_info "실행: ${dir}/${dir}.sh  (생성 파일 → poc-setup/${dir}/)"
    set +e
    (cd "$OUT_DIR" && bash "$SH_FILE")
    EXIT_CODE=$?
    set -e

    if [ $EXIT_CODE -eq 0 ]; then
        STEP_RESULTS[$((IDX-1))]="ok"
        print_ok "${dir} 완료"
    elif [ $EXIT_CODE -eq 77 ]; then
        STEP_RESULTS[$((IDX-1))]="skip"
        echo -e "${YELLOW}[make]${NC} ${dir} 건너뜀 (오퍼레이터 미설치)"
    else
        STEP_RESULTS[$((IDX-1))]="fail"
        print_error "${dir} 실패 (exit code: ${EXIT_CODE})"
        print_progress
        exit $EXIT_CODE
    fi

    print_progress
done

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  모든 단계 완료!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${CYAN}  poc- 네임스페이스 목록:${NC}"
echo ""
ns_desc() {
    case "$1" in
        poc-vm-management)  echo "03 VM 생성·스토리지·네트워크·Live Migration 실습" ;;
        poc-netpol-1)       echo "04 NetworkPolicy 실습 — NS1 (Deny All / Allow Same NS)" ;;
        poc-netpol-2)       echo "04 NetworkPolicy 실습 — NS2 (Deny All / Allow Same NS)" ;;
        poc-resource-quota) echo "05 ResourceQuota 실습 — CPU·Memory·Pod·PVC 제한" ;;
        poc-descheduler)    echo "06 Descheduler 실습 — 노드 과부하 시 VM 자동 재배치" ;;
        poc-maintenance)    echo "07 Node Maintenance 실습 — 노드 유지보수 시 VM Live Migration" ;;
        poc-snr)            echo "08 SNR 실습 — NHC 감지 → 노드 자가 재시작 복구" ;;
        poc-far)            echo "09 FAR 실습 — NHC 감지 → IPMI/BMC 전원 재시작 복구" ;;
        poc-liveness-probe) echo "10 Liveness Probe 실습 — HTTP·TCP·Exec Probe 설정 및 자동 재시작" ;;
        poc-mtv)            echo "16 MTV 실습 — VMware → OpenShift 마이그레이션" ;;
        poc-alert)          echo "11 VM Alert 실습 — PrometheusRule VM 상태 알림" ;;
        poc-node-exporter)  echo "12 Node Exporter 실습 — 커스텀 메트릭 수집" ;;
        poc-monitoring)     echo "13 모니터링 실습 — Grafana·Dell·Hitachi 스토리지" ;;
        poc-oadp)           echo "14 OADP 실습 — VM 백업/복원" ;;
        *)                  echo "" ;;
    esac
}
oc get namespace --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | grep '^poc-' | \
    while read -r ns; do
        desc=$(ns_desc "$ns")
        if [ -n "$desc" ]; then
            echo -e "    ${GREEN}●${NC} ${ns}  ${YELLOW}# ${desc}${NC}"
        else
            echo -e "    ${GREEN}●${NC} ${ns}"
        fi
    done
echo ""
