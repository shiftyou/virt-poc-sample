#!/bin/bash
# =============================================================================
# virt-poc-sample 환경 설정 스크립트
# OpenShift Virtualization POC 테스트를 위한 환경 변수를 수집하고
# env.conf 파일을 생성합니다.
#
# 사용법: ./setup.sh
# =============================================================================

set -euo pipefail

ENV_FILE="./env.conf"
EXAMPLE_FILE="./env.conf.example"

# 색상 출력 설정
RED='\033[0;31m'
GREEN='\033[0;32m'
DIM='\033[2m'
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

print_step_header() {
    local num="$1"
    local title="$2"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  ${num}  ${title}${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
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

# 값 입력 함수: prompt 메시지, 기본값, 변수명
ask() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"
    local is_secret="${4:-false}"

    if [ "$is_secret" = "true" ]; then
        echo -n -e "${YELLOW}  $prompt${NC} [기본값: ****]: "
        read -s input_val
        echo ""
    else
        echo -n -e "${YELLOW}  $prompt${NC} [기본값: ${default}]: "
        read input_val
    fi

    if [ -z "$input_val" ]; then
        input_val="$default"
    fi

    eval "$var_name='$input_val'"
}

# oc 명령어 확인
check_oc() {
    if ! command -v oc &> /dev/null; then
        print_warn "oc 명령어를 찾을 수 없습니다. OpenShift 클러스터 연결 없이 설정만 저장합니다."
        return 1
    fi

    if ! oc whoami &> /dev/null; then
        print_warn "OpenShift 클러스터에 로그인되어 있지 않습니다. 설정만 저장합니다."
        return 1
    fi

    print_ok "OpenShift 클러스터 연결 확인: $(oc whoami)"
    return 0
}

# 오퍼레이터 설치 확인
check_operators() {
    print_header "사전 준비: 오퍼레이터 설치 확인"

    VIRT_INSTALLED=false
    MTV_INSTALLED=false
    DESCHEDULER_INSTALLED=false
    FAR_INSTALLED=false
    NMO_INSTALLED=false
    NHC_INSTALLED=false
    SNR_INSTALLED=false
    NMSTATE_INSTALLED=false
    OADP_INSTALLED=false
    OADP_NS="openshift-adp"
    GRAFANA_INSTALLED=false
    COO_INSTALLED=false
    ODF_INSTALLED=false
    LOGGING_INSTALLED=false
    LOKI_INSTALLED=false

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
        if grep -qi "oadp-operator" /tmp/_poc_csv.txt 2>/dev/null; then
            OADP_INSTALLED=true
            OADP_NS=$(oc get csv -A 2>/dev/null | grep -i "oadp-operator" | awk '{print $1}' | head -1 || echo "openshift-adp")
        fi
        grep -qi "grafana-operator"               /tmp/_poc_csv.txt 2>/dev/null && GRAFANA_INSTALLED=true
        grep -qi "cluster-observability-operator" /tmp/_poc_csv.txt 2>/dev/null && COO_INSTALLED=true
        grep -qi "odf-operator\|ocs-operator"     /tmp/_poc_csv.txt 2>/dev/null && ODF_INSTALLED=true
        grep -qi "cluster-logging"                /tmp/_poc_csv.txt 2>/dev/null && LOGGING_INSTALLED=true
        grep -qi "loki-operator"                  /tmp/_poc_csv.txt 2>/dev/null && LOKI_INSTALLED=true
        rm -f /tmp/_poc_csv.txt
        # NMState CR 인스턴스 존재 여부 별도 확인
        NMSTATE_CR_EXISTS=false
        if [ "$NMSTATE_INSTALLED" = "true" ]; then
            oc get nmstate 2>/dev/null | grep -q "." && NMSTATE_CR_EXISTS=true || true
        fi
    else
        print_warn "클러스터에 연결되지 않아 오퍼레이터 상태를 확인할 수 없습니다."
        print_info "오퍼레이터 설치 방법: 00-operator/README.md 참조"
        echo ""
        return
    fi

    local ok="${GREEN}[✔]${NC}"
    local ng="${RED}[✘]${NC}"
    local wa="${YELLOW}[~]${NC}"

    echo ""
    printf "  %-45s %s\n" "오퍼레이터" "상태"
    echo "  ──────────────────────────────────────────────────────────"
    if [ "$VIRT_INSTALLED" = "true" ]; then
        echo -e "  $ok OpenShift Virtualization Operator  → Virtualization 사용 가능"
    else
        echo -e "  $ng OpenShift Virtualization Operator  → 미설치  (00-operator/)"
    fi
    if [ "$MTV_INSTALLED" = "true" ]; then
        echo -e "  $ok Migration Toolkit for Virt Operator → MTV 사용 가능"
    else
        echo -e "  $ng Migration Toolkit for Virt Operator → 미설치"
    fi
    if [ "$NMSTATE_INSTALLED" = "true" ] && [ "${NMSTATE_CR_EXISTS:-false}" = "true" ]; then
        echo -e "  $ok Kubernetes NMState Operator        → NodeNetworkState 조회 가능"
    elif [ "$NMSTATE_INSTALLED" = "true" ]; then
        echo -e "  $wa Kubernetes NMState Operator        → NMState CR 없음 (oc apply -f nmstate-cr.yaml 필요)  (00-operator/nmstate-operator.md)"
    else
        echo -e "  $ng Kubernetes NMState Operator        → NNCP/NNS 사용 불가  (00-operator/nmstate-operator.md)"
    fi
    if [ "$DESCHEDULER_INSTALLED" = "true" ]; then
        echo -e "  $ok Kube Descheduler Operator          → descheduler 구성 가능"
    else
        echo -e "  $ng Kube Descheduler Operator          → descheduler 구성 건너뜀  (00-operator/descheduler-operator.md)"
    fi
    if [ "$ODF_INSTALLED" = "true" ]; then
        echo -e "  $ok ODF Operator                       → OpenShift Data Foundation 사용 가능"
    else
        echo -e "  $ng ODF Operator                       → 미설치"
    fi
    if [ "$OADP_INSTALLED" = "true" ]; then
        echo -e "  $ok OADP Operator                      → 백업/복원 구성 가능  (ns: ${OADP_NS})"
    else
        echo -e "  $ng OADP Operator                      → 백업/복원 건너뜀  (00-operator/oadp-operator.md)"
    fi
    if [ "$GRAFANA_INSTALLED" = "true" ]; then
        echo -e "  $ok Grafana 커뮤니티 Operator          → Grafana 대시보드 구성 가능"
    else
        echo -e "  $ng Grafana 커뮤니티 Operator          → 미설치  (11-monitoring.md 참조)"
    fi
    if [ "$COO_INSTALLED" = "true" ]; then
        echo -e "  $ok Cluster Observability Operator     → MonitoringStack 사용 가능"
    else
        echo -e "  $ng Cluster Observability Operator     → 건너뜀  (00-operator/coo-operator.md)"
    fi
    if [ "$FAR_INSTALLED" = "true" ]; then
        echo -e "  $ok Fence Agents Remediation Operator  → FAR 구성 가능"
    else
        echo -e "  $ng Fence Agents Remediation Operator  → FAR 구성 건너뜀  (00-operator/far-operator.md)"
    fi
    if [ "$NMO_INSTALLED" = "true" ]; then
        echo -e "  $ok Node Maintenance Operator          → 노드 유지보수 가능"
    else
        echo -e "  $ng Node Maintenance Operator          → 노드 유지보수 건너뜀  (00-operator/node-maintenance-operator.md)"
    fi
    if [ "$NHC_INSTALLED" = "true" ]; then
        echo -e "  $ok Node Health Check Operator         → NHC 구성 가능"
    else
        echo -e "  $ng Node Health Check Operator         → NHC 구성 건너뜀  (00-operator/nhc-operator.md)"
    fi
    if [ "$SNR_INSTALLED" = "true" ]; then
        echo -e "  $ok Self Node Remediation Operator     → SNR 구성 가능"
    else
        echo -e "  $ng Self Node Remediation Operator     → SNR 구성 건너뜀  (00-operator/snr-operator.md)"
    fi
    if [ "$LOGGING_INSTALLED" = "true" ]; then
        echo -e "  $ok OpenShift Logging Operator         → 로그 수집 구성 가능"
    else
        echo -e "  $ng OpenShift Logging Operator         → 미설치"
    fi
    if [ "$LOKI_INSTALLED" = "true" ]; then
        echo -e "  $ok Loki Operator                      → LokiStack 구성 가능"
    else
        echo -e "  $ng Loki Operator                      → 미설치"
    fi
    echo "  ──────────────────────────────────────────────────────────"
    echo ""
}

# MinIO 자동 감지
auto_detect_minio() {
    MINIO_ENDPOINT=""
    MINIO_BUCKET="velero"
    MINIO_ACCESS_KEY="minio"
    MINIO_SECRET_KEY="minio123"

    # app=minio 레이블 서비스로 네임스페이스 탐색 (커뮤니티 standalone 배포 감지)
    local minio_ns
    minio_ns=$(oc get svc -A -l app=minio -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)

    MINIO_FOUND=false

    if [ -n "$minio_ns" ]; then
        local minio_svc minio_port
        minio_svc=$(oc get svc -n "$minio_ns" -l app=minio \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || \
            oc get svc -n "$minio_ns" \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
        minio_port=$(oc get svc -n "$minio_ns" "$minio_svc" \
            -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "9000")
        MINIO_ENDPOINT="http://${minio_svc}.${minio_ns}.svc.cluster.local:${minio_port}"

        # 자격증명 시크릿 탐색 (rootUser/rootPassword 또는 accesskey/secretkey)
        local secret_name
        secret_name=$(oc get secret -n "$minio_ns" \
            -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | \
            tr ' ' '\n' | grep -iE "minio|root|console" | head -1 || true)
        if [ -n "$secret_name" ]; then
            local ak sk
            ak=$(oc get secret -n "$minio_ns" "$secret_name" \
                -o jsonpath='{.data.rootUser}' 2>/dev/null | base64 -d 2>/dev/null || \
                oc get secret -n "$minio_ns" "$secret_name" \
                -o jsonpath='{.data.accesskey}' 2>/dev/null | base64 -d 2>/dev/null || true)
            sk=$(oc get secret -n "$minio_ns" "$secret_name" \
                -o jsonpath='{.data.rootPassword}' 2>/dev/null | base64 -d 2>/dev/null || \
                oc get secret -n "$minio_ns" "$secret_name" \
                -o jsonpath='{.data.secretkey}' 2>/dev/null | base64 -d 2>/dev/null || true)
            [ -n "$ak" ] && MINIO_ACCESS_KEY="$ak"
            [ -n "$sk" ] && MINIO_SECRET_KEY="$sk"
        fi

        MINIO_FOUND=true
        print_info "MinIO endpoint : ${MINIO_ENDPOINT}  (ns: ${minio_ns})"
        print_info "MinIO bucket   : ${MINIO_BUCKET}"
        print_info "MinIO accessKey: ${MINIO_ACCESS_KEY}"
    else
        print_warn "MinIO Service(app=minio) 감지 실패 → MinIO 설정을 건너뜁니다."
    fi
}

# ODF (NooBaa MCG) 자동 감지
auto_detect_odf() {
    ODF_S3_ENDPOINT=""
    ODF_S3_BUCKET="velero"
    ODF_S3_REGION="localstorage"
    ODF_S3_ACCESS_KEY=""
    ODF_S3_SECRET_KEY=""

    local odf_ns="openshift-storage"

    # NooBaa MCG S3 내부 엔드포인트
    ODF_S3_ENDPOINT=$(oc get noobaa -n "$odf_ns" \
        -o jsonpath='{.status.services.serviceS3.internalDNS[0]}' 2>/dev/null || true)
    if [ -z "$ODF_S3_ENDPOINT" ]; then
        # s3 서비스에서 직접 구성
        local s3_port
        s3_port=$(oc get svc s3 -n "$odf_ns" \
            -o jsonpath='{.spec.ports[?(@.name=="s3")].port}' 2>/dev/null || echo "80")
        ODF_S3_ENDPOINT="http://s3.${odf_ns}.svc.cluster.local:${s3_port}"
    fi

    # noobaa-admin 시크릿에서 자격증명 취득
    ODF_S3_ACCESS_KEY=$(oc get secret noobaa-admin -n "$odf_ns" \
        -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' 2>/dev/null | base64 -d 2>/dev/null || true)
    ODF_S3_SECRET_KEY=$(oc get secret noobaa-admin -n "$odf_ns" \
        -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' 2>/dev/null | base64 -d 2>/dev/null || true)

    if [ -n "$ODF_S3_ACCESS_KEY" ]; then
        print_info "ODF MCG S3 endpoint : ${ODF_S3_ENDPOINT}"
        print_info "ODF MCG region      : ${ODF_S3_REGION}"
        print_info "ODF MCG bucket      : ${ODF_S3_BUCKET}"
        print_info "ODF MCG credentials : noobaa-admin secret 에서 취득"
    else
        print_warn "ODF MCG 자격증명 감지 실패 (noobaa-admin secret 없음)"
    fi
}

# 클러스터 정보 자동 감지
auto_detect_cluster() {
    if check_oc; then
        DETECTED_API=$(oc whoami --show-server 2>/dev/null || echo "")
        DETECTED_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null | sed 's/^apps\.//' || echo "")
        if [ -n "$DETECTED_API" ]; then
            print_info "감지된 API 서버: $DETECTED_API"
        fi
        if [ -n "$DETECTED_DOMAIN" ]; then
            print_info "감지된 클러스터 도메인: $DETECTED_DOMAIN"
        fi

        # 스토리지클래스 자동 감지: virtualization 전용 → ceph-rbd 계열 → 기본값 순
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
            print_info "감지된 스토리지클래스: $DETECTED_SC"
        fi
        ALL_SC=$(oc get sc -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | tr '\n' ' ' || echo "")
        if [ -n "$ALL_SC" ]; then
            print_info "사용 가능한 스토리지클래스: $ALL_SC"
        fi

        # 노드 네트워크 인터페이스 자동 감지
        # 방법 1: NodeNetworkState (NMState operator, 빠름)
        FIRST_WORKER_FOR_NNS=$(oc get nodes -l node-role.kubernetes.io/worker \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        DETECTED_IFACES=""
        if [ -n "$FIRST_WORKER_FOR_NNS" ]; then
            # br-ex에 물린(controller=br-ex) 인터페이스 목록 수집
            local brex_slaves
            brex_slaves=$(oc get nns "$FIRST_WORKER_FOR_NNS" \
                -o jsonpath='{range .status.currentState.interfaces[*]}{.name}{" "}{.controller}{"\n"}{end}' \
                2>/dev/null | awk '$2=="br-ex"{print $1}' | tr '\n' '|' | sed 's/|$//' || true)
            # state=up 인 ethernet 인터페이스 중 br-ex 및 그 slave 제외
            DETECTED_IFACES=$(oc get nns "$FIRST_WORKER_FOR_NNS" \
                -o jsonpath='{range .status.currentState.interfaces[*]}{.name}{" "}{.type}{" "}{.state}{"\n"}{end}' \
                2>/dev/null | awk '$2=="ethernet" && $3=="up"{print $1}' | \
                grep -vE "^(br-ex|ovs-system)${brex_slaves:+|${brex_slaves}}" | \
                tr '\n' ' ' | xargs || true)
        fi
        # 방법 2: oc debug node (폴백, 느림 ~30초)
        if [ -z "$DETECTED_IFACES" ] && [ -n "$FIRST_WORKER_FOR_NNS" ]; then
            if [ "${NMSTATE_INSTALLED:-false}" = "true" ] && [ "${NMSTATE_CR_EXISTS:-false}" != "true" ]; then
                print_warn "NMState Operator가 설치되어 있지만 NMState CR이 없습니다."
                print_info "NodeNetworkState를 사용하려면: oc apply -f - <<'EOF'
apiVersion: nmstate.io/v1
kind: NMState
metadata:
  name: nmstate
EOF"
            fi
            print_info "NodeNetworkState 없음 → oc debug node 로 인터페이스 감지 중 (약 30초)..."
            # state UP + br-ex/ovs-system에 종속되지 않은 NIC만 포함
            DETECTED_IFACES=$(oc debug node/"$FIRST_WORKER_FOR_NNS" -- \
                chroot /host ip -o link show 2>/dev/null | \
                awk '/[Ss]tate UP/ && !/master ovs-system/ && !/master br-ex/ {split($2,a,"@"); gsub(/:$/,"",a[1]); print a[1]}' | \
                grep -vE '^(lo|ovs-system|br-ex|br-int|genev_sys|veth|tun|docker|ovn)' | \
                grep -E '^(ens|eth|eno|enp|em|bond)' | tr '\n' ' ' | xargs || true)
        fi
        DETECTED_IFACE=$(echo "$DETECTED_IFACES" | awk '{print $1}')
        if [ -n "$DETECTED_IFACES" ]; then
            print_info "감지된 네트워크 인터페이스 (노드: $FIRST_WORKER_FOR_NNS): $DETECTED_IFACES"
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
# 메인 실행
# =============================================================================

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  OpenShift Virtualization POC 환경 설정${NC}"
echo -e "${CYAN}  virt-poc-sample setup.sh${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# OpenShift 클러스터 로그인 확인
if ! command -v oc &>/dev/null; then
    print_error "oc 명령어를 찾을 수 없습니다. OpenShift CLI를 설치하세요."
    exit 1
fi
if ! oc whoami &>/dev/null; then
    print_error "OpenShift 클러스터에 로그인되어 있지 않습니다."
    print_info "먼저 'oc login' 으로 클러스터에 로그인하세요."
    exit 1
fi
print_ok "클러스터 접속 확인: $(oc whoami) @ $(oc whoami --show-server 2>/dev/null)"
echo ""

# 기존 env.conf 확인
if [ -f "$ENV_FILE" ]; then
    print_warn "기존 env.conf 파일이 존재합니다."
    echo -n -e "${YELLOW}  덮어쓰시겠습니까? (y/N): ${NC}"
    read overwrite
    if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
        print_info "설정을 취소했습니다. 기존 env.conf 파일을 사용합니다."
        exit 0
    fi
fi

# 클러스터 자동 감지 및 오퍼레이터 확인
auto_detect_cluster
check_operators

CONSOLE_ALLOWED_CIDRS="0.0.0.0/0"
API_ALLOWED_CIDRS="0.0.0.0/0"

# =============================================================================
# [ Cluster ] 클러스터 기본 정보
# =============================================================================
print_step_header "[ Cluster ]" "클러스터 기본 정보"

ask "클러스터 base domain (예: example.com)" "${DETECTED_DOMAIN:-example.com}" CLUSTER_DOMAIN
ask "API 서버 URL" "${DETECTED_API:-https://api.${CLUSTER_DOMAIN}:6443}" CLUSTER_API

# =============================================================================
# [01] Template — DataVolume / DataSource / Template 등록
# =============================================================================
print_step_header "[01]" "Template — DataVolume / DataSource / Template 등록"

ask "VM 이미지 업로드에 사용할 스토리지클래스" "${DETECTED_SC:-ocs-external-storagecluster-ceph-rbd}" STORAGE_CLASS
ask "poc-golden.qcow2 이미지 다운로드 URL" "http://krssa.ddns.net/vm-images/rhel9-poc-golden.qcow2" GOLDEN_IMAGE_URL

# =============================================================================
# [02] Network — NNCP / NAD / VM 생성
# =============================================================================
print_step_header "[02]" "Network — NNCP / NAD / VM 생성"

# NNCP 목록 표시 및 linux-bridge 선택
NNCP_NAME="br-poc-nncp"
_USE_EXISTING_NNCP=false
_LB_NNCPS=()

if command -v oc &>/dev/null && oc whoami &>/dev/null 2>&1; then
    _ALL_NNCPS=$(oc get nncp -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -v '^$' || true)

    if [ -n "$_ALL_NNCPS" ]; then
        echo ""
        print_info "현재 클러스터 NNCP 목록:"
        echo ""
        printf "  %-4s %-32s %-15s %-18s %-8s %s\n" "번호" "NNCP 이름" "타입" "Bridge 이름" "상태" "NIC"
        echo "  ──────────────────────────────────────────────────────────────────────────────────"
        _idx=1
        for _n in $_ALL_NNCPS; do
            _br=$(oc get nncp "$_n" \
                -o jsonpath='{range .spec.desiredState.interfaces[?(@.type=="linux-bridge")]}{.name}{end}' \
                2>/dev/null || true)
            _avail=$(oc get nncp "$_n" \
                -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' \
                2>/dev/null || true)
            if [ -n "$_br" ]; then
                _nic=$(oc get nncp "$_n" \
                    -o jsonpath='{range .spec.desiredState.interfaces[?(@.type=="linux-bridge")]}{.bridge.port[0].name}{end}' \
                    2>/dev/null || true)
                _type="linux-bridge"
                _LB_NNCPS+=("$_n")
                printf "  ${GREEN}%-4s %-32s %-15s %-18s %-8s %s${NC}\n" \
                    "${_idx})" "$_n" "$_type" "${_br:-N/A}" "${_avail:-Unknown}" "${_nic:-N/A}"
            else
                printf "  ${DIM}%-4s %-32s %-15s %-18s %-8s %s${NC}\n" \
                    "${_idx})" "$_n" "other" "-" "${_avail:-Unknown}" "-"
            fi
            _idx=$((_idx + 1))
        done
        echo ""
    else
        echo ""
        print_info "클러스터에 NNCP가 없습니다."
    fi
fi

if [ ${#_LB_NNCPS[@]} -gt 0 ]; then
    _FIRST_LB="${_LB_NNCPS[0]}"
    if [ ${#_LB_NNCPS[@]} -eq 1 ]; then
        _cand_br=$(oc get nncp "$_FIRST_LB" \
            -o jsonpath='{range .spec.desiredState.interfaces[?(@.type=="linux-bridge")]}{.name}{end}' \
            2>/dev/null || true)
        _cand_nic=$(oc get nncp "$_FIRST_LB" \
            -o jsonpath='{range .spec.desiredState.interfaces[?(@.type=="linux-bridge")]}{.bridge.port[0].name}{end}' \
            2>/dev/null || true)
        echo -n -e "${YELLOW}  linux-bridge NNCP '${_FIRST_LB}' (bridge: ${_cand_br}, NIC: ${_cand_nic:-N/A})을 사용하시겠습니까? (Y/n): ${NC}"
        read _use_existing
        if [[ ! "${_use_existing:-}" =~ ^[Nn]$ ]]; then
            _USE_EXISTING_NNCP=true
            NNCP_NAME="$_FIRST_LB"
            BRIDGE_NAME="${_cand_br:-br-poc}"
            BRIDGE_INTERFACE="${_cand_nic:-${DETECTED_IFACE:-ens4}}"
            print_ok "선택: ${NNCP_NAME}  (bridge: ${BRIDGE_NAME}, NIC: ${BRIDGE_INTERFACE})"
        fi
    else
        echo -n -e "${YELLOW}  linux-bridge NNCP 번호 또는 이름을 선택하세요 [기본값: ${_FIRST_LB}] (없으면 엔터 후 n): ${NC}"
        read _sel_input
        if [ -z "$_sel_input" ]; then
            _sel_nncp="$_FIRST_LB"
        elif [[ "$_sel_input" =~ ^[0-9]+$ ]]; then
            _sel_nncp="${_LB_NNCPS[$((_sel_input - 1))]:-$_FIRST_LB}"
        else
            _sel_nncp="$_sel_input"
        fi
        _sel_br=$(oc get nncp "$_sel_nncp" \
            -o jsonpath='{range .spec.desiredState.interfaces[?(@.type=="linux-bridge")]}{.name}{end}' \
            2>/dev/null || true)
        _sel_nic=$(oc get nncp "$_sel_nncp" \
            -o jsonpath='{range .spec.desiredState.interfaces[?(@.type=="linux-bridge")]}{.bridge.port[0].name}{end}' \
            2>/dev/null || true)
        echo -n -e "${YELLOW}  '${_sel_nncp}' (bridge: ${_sel_br}, NIC: ${_sel_nic:-N/A})을 사용하시겠습니까? (Y/n): ${NC}"
        read _use_existing
        if [[ ! "${_use_existing:-}" =~ ^[Nn]$ ]]; then
            _USE_EXISTING_NNCP=true
            NNCP_NAME="$_sel_nncp"
            BRIDGE_NAME="${_sel_br:-br-poc}"
            BRIDGE_INTERFACE="${_sel_nic:-${DETECTED_IFACE:-ens4}}"
            print_ok "선택: ${NNCP_NAME}  (bridge: ${BRIDGE_NAME}, NIC: ${BRIDGE_INTERFACE})"
        fi
    fi
fi

if [ "$_USE_EXISTING_NNCP" = "false" ]; then
    echo ""
    if [ -n "${DETECTED_IFACES:-}" ]; then
        print_info "감지된 인터페이스 목록: $DETECTED_IFACES"
    else
        print_info "노드의 네트워크 인터페이스 확인: oc debug node/<node> -- ip link show"
    fi
    ask "생성할 Linux Bridge 이름" "br-poc" BRIDGE_NAME
    BRIDGE_INTERFACE="${DETECTED_IFACE:-ens4}"
    NNCP_NAME="${BRIDGE_NAME}-nncp"
    print_info "  NIC       : ${BRIDGE_INTERFACE}"
    print_info "  NNCP 이름 : ${NNCP_NAME}"
    echo ""
    echo -n -e "${YELLOW}  nncp-gen.sh를 실행하여 NNCP를 지금 생성하시겠습니까? (Y/n): ${NC}"
    read _run_nncp_gen
    if [[ ! "${_run_nncp_gen:-}" =~ ^[Nn]$ ]]; then
        _SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        export BRIDGE_NAME BRIDGE_INTERFACE NNCP_NAME
        bash "${_SETUP_DIR}/02-network/nncp-gen.sh" 1
    fi
fi

echo ""
print_info "SECONDARY_IP_PREFIX: secondary NIC(eth1) cloud-init 정적 IP 할당 시 사용하는 네트워크 프리픽스입니다."
print_info "  예) 192.168.100 → 02-network VM: .21, .22 / 03-vm: .31 / 05-network-policy: .51, .52"
ask "Secondary NIC IP 프리픽스 (cloud-init networkData)" "192.168.100" SECONDARY_IP_PREFIX

# =============================================================================
# [10] Monitoring — Grafana 대시보드
# =============================================================================
if [ "${GRAFANA_INSTALLED:-false}" = "true" ]; then
    print_step_header "[10]" "Monitoring — Grafana 대시보드"
    ask "Grafana admin 비밀번호" "grafana123" GRAFANA_ADMIN_PASS "true"
else
    print_info "[10] Monitoring — Grafana Operator 미설치, 건너뜁니다."
    GRAFANA_ADMIN_PASS="grafana123"
fi

# =============================================================================
# [11] MTV — VMware → OpenShift 마이그레이션
# =============================================================================
if [ "${MTV_INSTALLED:-false}" = "true" ]; then
    print_step_header "[11]" "MTV — VMware → OpenShift 마이그레이션"
    print_info "VDDK 이미지 경로 (내부 레지스트리에 직접 push 후 입력)"
    ask "VDDK 이미지 경로" "image-registry.openshift-image-registry.svc:5000/openshift/vddk:latest" VDDK_IMAGE
else
    print_info "[11] MTV — MTV Operator 미설치, 건너뜁니다."
    VDDK_IMAGE="image-registry.openshift-image-registry.svc:5000/openshift/vddk:latest"
fi

# =============================================================================
# [12] OADP — VM 백업/복원 (MinIO / ODF backend 자동 감지)
# =============================================================================
if [ "${OADP_INSTALLED:-false}" = "true" ]; then
    print_step_header "[12]" "OADP — VM 백업/복원 backend 설정"

    # MinIO 운영 여부 감지
    auto_detect_minio

    if [ "${MINIO_FOUND}" = "true" ]; then
        print_ok "MinIO 운영 중 감지 — 연결 정보를 확인하세요."
        echo ""

        # Route가 있으면 외부 URL로 제안
        local minio_route
        minio_route=$(oc get route minio-api -n minio \
            -o jsonpath='https://{.status.ingress[0].host}' 2>/dev/null || true)
        [ -n "$minio_route" ] && MINIO_ENDPOINT="$minio_route"

        ask "MinIO API Endpoint" "${MINIO_ENDPOINT}" MINIO_ENDPOINT
        ask "MinIO Access Key"   "${MINIO_ACCESS_KEY}" MINIO_ACCESS_KEY
        ask "MinIO Secret Key"   "${MINIO_SECRET_KEY}" MINIO_SECRET_KEY "true"
        ask "OADP (Velero) 전용 S3 Bucket" "${OADP_S3_BUCKET:-velero}" OADP_S3_BUCKET
        MINIO_BUCKET="${OADP_S3_BUCKET}"
        MINIO_FOUND=true

        # ODF도 있으면 추가 감지
        if [ "${ODF_INSTALLED:-false}" = "true" ]; then
            auto_detect_odf
        else
            ODF_S3_ENDPOINT=""
            ODF_S3_BUCKET="${OADP_S3_BUCKET}"
            ODF_S3_REGION="localstorage"
            ODF_S3_ACCESS_KEY=""
            ODF_S3_SECRET_KEY=""
        fi
    else
        MINIO_ENDPOINT=""
        MINIO_ACCESS_KEY=""
        MINIO_SECRET_KEY=""
        print_info "MinIO 미감지 → ODF(NooBaa MCG)를 OADP backend로 사용합니다."
        print_info "MinIO를 사용하려면 먼저 배포 후 setup.sh 재실행하세요 (13-oadp.md 참조)"
        if [ "${ODF_INSTALLED:-false}" = "true" ]; then
            auto_detect_odf
            print_info "ODF 백엔드: 버킷 이름은 ObjectBucketClaim(OBC)이 자동 생성합니다."
            print_info "  → 13-oadp.sh 실행 시 'backups-xxxx' 형식으로 결정됩니다."
            OADP_S3_BUCKET="(obc-auto)"
            ODF_S3_BUCKET="${OADP_S3_BUCKET}"
        else
            print_warn "ODF Operator도 미설치 — OADP backend 설정을 건너뜁니다."
            ODF_S3_ENDPOINT=""
            ODF_S3_BUCKET="velero"
            ODF_S3_REGION="localstorage"
            ODF_S3_ACCESS_KEY=""
            ODF_S3_SECRET_KEY=""
            OADP_S3_BUCKET="${OADP_S3_BUCKET:-velero}"
        fi
        MINIO_BUCKET="${OADP_S3_BUCKET:-velero}"
    fi
else
    print_info "[12] OADP — OADP Operator 미설치, 건너뜁니다."
    MINIO_ENDPOINT=""
    MINIO_BUCKET="velero"
    MINIO_ACCESS_KEY=""
    MINIO_SECRET_KEY=""
    ODF_S3_ENDPOINT=""
    ODF_S3_BUCKET="velero"
    ODF_S3_REGION="localstorage"
    ODF_S3_ACCESS_KEY=""
    ODF_S3_SECRET_KEY=""
    OADP_S3_BUCKET="${OADP_S3_BUCKET:-velero}"
fi

# =============================================================================
# [19] Logging — LokiStack S3 Bucket 설정 (OADP와 별도)
# =============================================================================
if [ "${LOKI_INSTALLED:-false}" = "true" ]; then
    print_step_header "[19]" "Logging — LokiStack 전용 S3 Bucket 설정"
    echo ""
    print_info "LokiStack은 OADP(Velero)와 다른 버킷을 사용해야 합니다."
    print_info "  OADP bucket : ${OADP_S3_BUCKET:-velero}"
    echo ""
    ask "Loki 전용 S3 Bucket" "${LOGGING_S3_BUCKET:-loki}" LOGGING_S3_BUCKET
else
    LOGGING_S3_BUCKET="${LOGGING_S3_BUCKET:-loki}"
fi

# =============================================================================
# [09] Alert — VM Stop 알림
# =============================================================================
print_step_header "[09]" "Alert — VM Stop 알림 (PrometheusRule / OpenShift Console)"
echo ""
print_info "Alert 은 OpenShift Console → Observe → Alerting 에서 확인합니다."
ask "감시할 VM 이름" "poc-alert-vm" ALERT_VM_NAME
ask "감시할 VM 네임스페이스" "poc-alert" ALERT_VM_NS

# =============================================================================
# [13·14·16] Node — 노드 유지보수 / SNR / Add Node
# =============================================================================
print_step_header "[13·14·16]" "Node — 노드 유지보수 / SNR / Add Node"

if check_oc 2>/dev/null; then
    DETECTED_WORKERS=$(oc get nodes -l node-role.kubernetes.io/worker \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$DETECTED_WORKERS" ]; then
        print_info "감지된 워커 노드: $DETECTED_WORKERS"
        FIRST_WORKER=$(echo $DETECTED_WORKERS | awk '{print $1}')
    else
        FIRST_WORKER="worker-0"
    fi
else
    DETECTED_WORKERS=""
    FIRST_WORKER="worker-0"
fi

ask "워커 노드 이름 목록 (공백으로 구분)" "${DETECTED_WORKERS:-worker-0 worker-1 worker-2}" WORKER_NODES
ask "테스트용 단일 노드 이름" "${FIRST_WORKER:-worker-0}" TEST_NODE

# =============================================================================
# [15] FAR — IPMI/BMC 전원 재시작 복구
# =============================================================================
if [ "${FAR_INSTALLED:-false}" = "true" ]; then
    print_step_header "[15]" "FAR — Fence Agents Remediation (IPMI/BMC)"
    ask "IPMI 사용자 이름" "admin" FENCE_AGENT_USER
    ask "IPMI 비밀번호" "password" FENCE_AGENT_PASS "true"
    echo ""
    print_info "워커 노드별 IPMI/BMC IP 주소를 입력하세요."
    FENCE_AGENT_IPS=""
    _ipmi_idx=1
    for _node in ${WORKER_NODES}; do
        ask "  ${_node} IPMI/BMC IP" "192.168.1.${_ipmi_idx}" _node_ipmi_ip
        FENCE_AGENT_IPS="${FENCE_AGENT_IPS:+${FENCE_AGENT_IPS} }${_node_ipmi_ip}"
        _ipmi_idx=$((_ipmi_idx + 1))
    done
    print_ok "IPMI IP 목록: ${FENCE_AGENT_IPS}"
else
    print_info "[15] FAR — FAR Operator 미설치, 건너뜁니다."
    FENCE_AGENT_IPS=""
    FENCE_AGENT_USER="admin"
    FENCE_AGENT_PASS="password"
fi

# =============================================================================
# env.conf 저장
# =============================================================================
print_header "env.conf 저장 중..."

cat > "$ENV_FILE" << EOF
# =============================================================================
# virt-poc-sample 환경 설정 파일
# setup.sh 에 의해 자동 생성됨: $(date)
# 이 파일은 .gitignore 에 등록되어 있으므로 git에 커밋되지 않습니다.
# =============================================================================

# 클러스터 기본 정보
CLUSTER_DOMAIN=${CLUSTER_DOMAIN}
CLUSTER_API=${CLUSTER_API}

# 네트워크 설정
NNCP_NAME=${NNCP_NAME}
BRIDGE_INTERFACE=${BRIDGE_INTERFACE}
BRIDGE_NAME=${BRIDGE_NAME}
SECONDARY_IP_PREFIX=${SECONDARY_IP_PREFIX}

# 스토리지클래스
STORAGE_CLASS=${STORAGE_CLASS}

# Golden Image URL (DataVolume HTTP import)
GOLDEN_IMAGE_URL=${GOLDEN_IMAGE_URL}

# Alert 설정 (09-alert)
ALERT_VM_NAME=${ALERT_VM_NAME}
ALERT_VM_NS=${ALERT_VM_NS}

# VDDK 이미지
VDDK_IMAGE=${VDDK_IMAGE}

# Console / API 접근 IP 제한
CONSOLE_ALLOWED_CIDRS=${CONSOLE_ALLOWED_CIDRS}
API_ALLOWED_CIDRS=${API_ALLOWED_CIDRS}

# Fence Agents Remediation
FENCE_AGENT_IPS="${FENCE_AGENT_IPS}"
FENCE_AGENT_USER=${FENCE_AGENT_USER}
FENCE_AGENT_PASS=${FENCE_AGENT_PASS}

# 노드 정보
WORKER_NODES="${WORKER_NODES}"
TEST_NODE=${TEST_NODE}

# Grafana
GRAFANA_ADMIN_PASS=${GRAFANA_ADMIN_PASS}

# MinIO 커뮤니티 (OADP backend)
MINIO_INSTALLED=${MINIO_FOUND:-false}
MINIO_ENDPOINT=${MINIO_ENDPOINT}
MINIO_BUCKET=${MINIO_BUCKET}
MINIO_ACCESS_KEY=${MINIO_ACCESS_KEY}
MINIO_SECRET_KEY=${MINIO_SECRET_KEY}

# ODF MCG (OADP backend)
ODF_S3_ENDPOINT=${ODF_S3_ENDPOINT}
ODF_S3_BUCKET=${ODF_S3_BUCKET}
ODF_S3_REGION=${ODF_S3_REGION}
ODF_S3_ACCESS_KEY=${ODF_S3_ACCESS_KEY}
ODF_S3_SECRET_KEY=${ODF_S3_SECRET_KEY}

# 용도별 전용 버킷 (공유 endpoint, 별도 bucket)
OADP_S3_BUCKET=${OADP_S3_BUCKET:-velero}
LOGGING_S3_BUCKET=${LOGGING_S3_BUCKET:-loki}

# 오퍼레이터 설치 여부 (setup.sh 실행 시 자동 감지)
VIRT_INSTALLED=${VIRT_INSTALLED:-false}
MTV_INSTALLED=${MTV_INSTALLED:-false}
NMSTATE_INSTALLED=${NMSTATE_INSTALLED:-false}
OADP_INSTALLED=${OADP_INSTALLED:-false}
OADP_NS=${OADP_NS:-openshift-adp}
GRAFANA_INSTALLED=${GRAFANA_INSTALLED:-false}
COO_INSTALLED=${COO_INSTALLED:-false}
DESCHEDULER_INSTALLED=${DESCHEDULER_INSTALLED:-false}
FAR_INSTALLED=${FAR_INSTALLED:-false}
NMO_INSTALLED=${NMO_INSTALLED:-false}
NHC_INSTALLED=${NHC_INSTALLED:-false}
SNR_INSTALLED=${SNR_INSTALLED:-false}
ODF_INSTALLED=${ODF_INSTALLED:-false}
LOGGING_INSTALLED=${LOGGING_INSTALLED:-false}
LOKI_INSTALLED=${LOKI_INSTALLED:-false}
EOF

print_ok "env.conf 파일이 생성되었습니다: $ENV_FILE"

# =============================================================================
# 완료 메시지
# =============================================================================
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  설정 완료!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  다음 단계:"
echo -e ""
echo -e "  ${CYAN}[1] 오퍼레이터 설치${NC}"
echo -e "      00-operator/README.md"
echo -e ""
echo -e "  ${CYAN}[2] make.sh 실행${NC}"
echo -e "      ./make.sh"
echo ""
