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
# 사용법:
#   ./make.sh            사용법 출력
#   ./make.sh start      전체 실행
#   ./make.sh 7          07 단계만 실행
#   ./make.sh from 7     07 단계부터 끝까지 실행
#   ./make.sh clean      poc- 네임스페이스 전체 삭제
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
print_warn()  { echo -e "${YELLOW}[make]${NC} $1"; }

# 인수 파싱
ARG1="${1:-}"
ARG2="${2:-}"

# =============================================================================
# 인수 없음 → 사용법 출력
# =============================================================================
if [ -z "$ARG1" ]; then
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  virt-poc-sample make.sh${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  사용법:"
    echo -e "    ${CYAN}./make.sh start${NC}        전체 실행"
    echo -e "    ${CYAN}./make.sh 7${NC}            07 단계만 실행"
    echo -e "    ${CYAN}./make.sh from 7${NC}       07 단계부터 끝까지 실행"
    echo -e "    ${CYAN}./make.sh clean${NC}        poc- 네임스페이스 전체 삭제"
    echo ""
    exit 0
fi

# =============================================================================
# clean 서브커맨드
# =============================================================================
if [ "$ARG1" = "clean" ]; then
    if ! oc whoami &>/dev/null; then
        print_error "OpenShift 에 로그인되어 있지 않습니다."
        exit 1
    fi

    NAMESPACES=$(oc get namespace --no-headers \
        -o custom-columns=NAME:.metadata.name 2>/dev/null | grep '^poc-' || true)

    if [ -z "$NAMESPACES" ]; then
        print_info "삭제할 poc- 네임스페이스가 없습니다."
        exit 0
    fi

    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  make.sh clean — 아래 네임스페이스를 삭제합니다${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "$NAMESPACES" | while read -r ns; do
        echo -e "    ${YELLOW}●${NC} ${ns}"
    done
    echo ""
    echo -n -e "${YELLOW}  정말 삭제하시겠습니까? (y/N): ${NC}"
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "취소했습니다."
        exit 0
    fi

    echo ""
    echo "$NAMESPACES" | while read -r ns; do
        print_info "삭제 중: ${ns}"
        oc delete namespace "$ns" --wait=false 2>/dev/null && \
            print_ok "${ns} 삭제 요청 완료" || \
            print_warn "${ns} 삭제 실패 (이미 없거나 권한 부족)"
    done

    echo ""
    print_info "네임스페이스 삭제 완료를 기다리는 중..."
    echo ""
    while true; do
        REMAINING=$(oc get namespace --no-headers \
            -o custom-columns=NAME:.metadata.name 2>/dev/null | grep '^poc-' || true)
        if [ -z "$REMAINING" ]; then
            break
        fi
        echo -e "  ${YELLOW}남은 네임스페이스:${NC}"
        echo "$REMAINING" | while read -r ns; do
            echo -e "    ${YELLOW}●${NC} ${ns}"
        done
        sleep 5
        echo ""
    done
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  모든 poc- 네임스페이스 삭제 완료!${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    exit 0
fi

# env.conf 확인 및 로드
if [ ! -f "$ENV_FILE" ]; then
    print_error "env.conf 가 없습니다. 먼저 setup.sh 를 실행하세요."
    exit 1
fi

set -a
source "$ENV_FILE"
set +a

POC_SETUP_DIR="${SCRIPT_DIR}/poc-setup"

# 실행 모드 결정
MODE="all"
START_NUM=""

if [ "$ARG1" = "from" ] && [[ "$ARG2" =~ ^[0-9]+$ ]]; then
    MODE="from"
    START_NUM=$(printf "%02d" "$ARG2")
elif [[ "$ARG1" =~ ^[0-9]+$ ]]; then
    MODE="only"
    START_NUM=$(printf "%02d" "$ARG1")
elif [ "$ARG1" != "start" ]; then
    print_error "알 수 없는 인수: $ARG1"
    echo -e "  ${CYAN}./make.sh${NC} 를 실행하면 사용법을 확인할 수 있습니다."
    exit 1
fi

# 번호 디렉토리를 정렬해서 수집
ALL_STEPS=()
while IFS= read -r dir; do
    ALL_STEPS+=("$(basename "$dir")")
done < <(find "$SCRIPT_DIR" -maxdepth 1 -type d -name '[0-9][0-9]-*' | grep -v '/00-' | sort)

if [ ${#ALL_STEPS[@]} -eq 0 ]; then
    print_error "실행할 단계가 없습니다. 01-, 02-... 디렉토리 없음"
    exit 1
fi

# 모드에 따라 실행할 단계 필터링
STEPS=()
for dir in "${ALL_STEPS[@]}"; do
    NUM="${dir:0:2}"
    NUM_INT=$((10#$NUM))
    START_INT=$((10#${START_NUM:-0}))
    case "$MODE" in
        only) [ "$NUM_INT" -eq "$START_INT" ] && STEPS+=("$dir") ;;
        from) [ "$NUM_INT" -ge "$START_INT" ] && STEPS+=("$dir") ;;
        all)  STEPS+=("$dir") ;;
    esac
done

if [ ${#STEPS[@]} -eq 0 ]; then
    print_error "실행할 단계가 없습니다. (번호 ${START_NUM} 에 해당하는 디렉토리가 없음)"
    exit 1
fi

# poc-setup 디렉토리 정리
if [ "$MODE" = "all" ]; then
    if [ -d "$POC_SETUP_DIR" ]; then
        print_info "poc-setup 전체 삭제 후 시작..."
        rm -rf "$POC_SETUP_DIR"
    fi
elif [ "$MODE" = "only" ]; then
    for dir in "${STEPS[@]}"; do
        if [ -d "${POC_SETUP_DIR}/${dir}" ]; then
            print_info "poc-setup/${dir} 삭제 후 시작..."
            rm -rf "${POC_SETUP_DIR:?}/${dir}"
        fi
    done
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
        01-template)         echo "DataVolume 업로드 → DataSource → Template 등록" ;;
        02-network)          echo "NNCP Linux Bridge + NAD + VM 생성" ;;
        03-vm-management)    echo "네임스페이스 + NAD 준비" ;;
        04-multitenancy)     echo "멀티 테넌트 — 네임스페이스·사용자·RBAC·VM" ;;
        05-network-policy)   echo "NetworkPolicy — Deny All / Allow Same NS / Allow IP" ;;
        06-resource-quota)   echo "ResourceQuota — CPU·Memory·Pod·PVC 제한" ;;
        07-descheduler)      echo "Descheduler — VM 자동 재배치 (Operator 필요)" ;;
        08-liveness-probe)   echo "VM Liveness Probe — HTTP·TCP·Exec" ;;
        09-alert)            echo "VM Alert — PrometheusRule 알림" ;;
        10-node-exporter)    echo "Node Exporter — 커스텀 메트릭 수집" ;;
        11-monitoring)       echo "Grafana 모니터링 (Operator 필요)" ;;
        12-mtv)              echo "MTV — VMware → OpenShift 마이그레이션 (Operator 필요)" ;;
        13-oadp)             echo "OADP — VM 백업/복원 (Operator 필요)" ;;
        14-node-maintenance) echo "Node Maintenance — 노드 유지보수 VM Migration (Operator 필요)" ;;
        15-snr)              echo "SNR — 노드 자가 재시작 복구 (Operator 필요)" ;;
        16-far)              echo "FAR — IPMI/BMC 전원 재시작 복구 (Operator 필요)" ;;
        17-add-node)         echo "워커 노드 제거 후 재조인" ;;
        18-hyperconverged)   echo "HyperConverged — CPU Overcommit 설정" ;;
        *)                   echo "$1" ;;
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

# =============================================================================
# oc patch wrapper — patch 실행 후 최종 YAML 을 poc-setup/<step>/ 에 저장
# =============================================================================
_OC_WRAP_DIR=""
if command -v oc &>/dev/null; then
    _OC_REAL=$(command -v oc)
    _OC_WRAP_DIR=$(mktemp -d)
    echo "${_OC_REAL}" > "${_OC_WRAP_DIR}/.oc_real"
    cat > "${_OC_WRAP_DIR}/oc" <<'OC_WRAPPER_EOF'
#!/bin/bash
# oc wrapper: 'oc patch' 실행 후 최종 YAML 을 POC_PATCH_SAVE_DIR 에 저장
_R=$(cat "$(dirname "${BASH_SOURCE[0]}")/.oc_real")
"$_R" "$@"
_X=$?
if [ "${1:-}" = "patch" ] && [ "$_X" -eq 0 ] && [ -n "${POC_PATCH_SAVE_DIR:-}" ]; then
    _K="${2:-}"; _N="${3:-}"; _NS=""; _P=""
    for _A in "$@"; do
        { [ "$_P" = "-n" ] || [ "$_P" = "--namespace" ]; } && _NS="$_A"
        case "$_A" in --namespace=*) _NS="${_A#--namespace=}" ;; esac
        _P="$_A"
    done
    if [ -n "$_K" ] && [ -n "$_N" ]; then
        _FNAME=$(echo "${_K}-${_N}" | tr '/' '-')
        _OUT="${POC_PATCH_SAVE_DIR}/${_FNAME}-patched.yaml"
        if [ -n "$_NS" ]; then
            "$_R" get "$_K" "$_N" -n "$_NS" -o yaml > "$_OUT" 2>/dev/null && \
                echo -e "\033[0;34m[patch-save]\033[0m ${_FNAME}-patched.yaml" || true
        else
            "$_R" get "$_K" "$_N" -o yaml > "$_OUT" 2>/dev/null && \
                echo -e "\033[0;34m[patch-save]\033[0m ${_FNAME}-patched.yaml" || true
        fi
    fi
fi
exit "$_X"
OC_WRAPPER_EOF
    chmod +x "${_OC_WRAP_DIR}/oc"
fi

# 시작 헤더
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
case "$MODE" in
    only) echo -e "${CYAN}  virt-poc-sample — ${START_NUM} 단계만 실행${NC}" ;;
    from) echo -e "${CYAN}  virt-poc-sample — ${START_NUM} 단계부터 실행 (총 ${TOTAL}단계)${NC}" ;;
    all)  echo -e "${CYAN}  virt-poc-sample 전체 실행 (총 ${TOTAL}단계)${NC}" ;;
esac
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
    if [ -n "${_OC_WRAP_DIR:-}" ]; then
        (cd "$OUT_DIR" && PATH="${_OC_WRAP_DIR}:${PATH}" POC_PATCH_SAVE_DIR="$OUT_DIR" bash "$SH_FILE")
    else
        (cd "$OUT_DIR" && bash "$SH_FILE")
    fi
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

# oc wrapper 정리
if [ -n "${_OC_WRAP_DIR:-}" ]; then
    rm -rf "${_OC_WRAP_DIR}"
fi

if [ "$MODE" != "only" ]; then
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
        tenant-ns1)               echo "04 멀티 테넌트 — NS1 (user1 admin / user3 view)" ;;
        tenant-ns2)               echo "04 멀티 테넌트 — NS2 (user2 admin / user4 view)" ;;
        poc-network-policy-1)     echo "05 NetworkPolicy 실습 — NS1 (Deny All / Allow Same NS)" ;;
        poc-network-policy-2)     echo "05 NetworkPolicy 실습 — NS2 (Deny All / Allow Same NS)" ;;
        poc-resource-quota)       echo "06 ResourceQuota 실습 — CPU·Memory·Pod·PVC 제한" ;;
        poc-descheduler)          echo "07 Descheduler 실습 — 노드 과부하 시 VM 자동 재배치" ;;
        poc-liveness-probe)       echo "08 Liveness Probe 실습 — HTTP·TCP·Exec Probe 설정 및 자동 재시작" ;;
        poc-alert)                echo "09 VM Alert 실습 — PrometheusRule VM 상태 알림" ;;
        poc-node-exporter)        echo "10 Node Exporter 실습 — 커스텀 메트릭 수집" ;;
        poc-monitoring)           echo "11 모니터링 실습 — Grafana·Dell·Hitachi 스토리지" ;;
        poc-mtv)                  echo "12 MTV 실습 — VMware → OpenShift 마이그레이션" ;;
        poc-oadp)                 echo "13 OADP 실습 — VM 백업/복원" ;;
        poc-maintenance)          echo "14 Node Maintenance 실습 — 노드 유지보수 시 VM Live Migration" ;;
        poc-snr)                  echo "15 SNR 실습 — NHC 감지 → 노드 자가 재시작 복구" ;;
        poc-far)                  echo "16 FAR 실습 — NHC 감지 → IPMI/BMC 전원 재시작 복구" ;;
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
fi
