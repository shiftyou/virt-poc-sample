#!/bin/bash
# =============================================================================
# 19-logging.sh
#
# OpenShift Audit Logging 구성
# APIServer Audit Policy 설정 + OpenShift Logging Operator를 통한 수집·전달
#
#   1. APIServer Audit Policy 선택·설정
#   2. OpenShift Logging Operator 확인
#   3. ClusterLogging 인스턴스 생성
#   4. LokiStack 생성 (Loki Operator 설치 시, MinIO S3 사용)
#   5. ClusterLogForwarder (Audit 로그 포함) 구성
#   6. 상태 확인
#
# 사용법: ./19-logging.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

LOGGING_NS="openshift-logging"
LOKI_NAME="logging-loki"
CLF_NAME="instance"
CL_NAME="instance"
STORAGE_CLASS="${STORAGE_CLASS:-ocs-storagecluster-ceph-rbd}"
MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://minio.poc-minio.svc.cluster.local:9000}"
MINIO_BUCKET="${MINIO_BUCKET:-loki}"
MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY:-minio}"
MINIO_SECRET_KEY="${MINIO_SECRET_KEY:-minio123}"

AUDIT_PROFILE=""
HAS_LOGGING=false
HAS_LOKI=false
LOGGING_V6=false

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

# YAML 미리보기 후 확인하고 적용
confirm_and_apply() {
    local file="$1"
    echo ""
    print_info "적용할 YAML:"
    echo "────────────────────────────────────────"
    cat "$file"
    echo "────────────────────────────────────────"
    read -r -p "위 YAML을 클러스터에 적용하시겠습니까? [y/N]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { print_warn "취소되었습니다."; exit 0; }
    oc apply -f "$file"
}

# =============================================================================
# Audit Policy 프로필 선택
# =============================================================================
choose_audit_profile() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  APIServer Audit Policy 프로필을 선택하세요${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${GREEN}1)${NC} Default"
    echo -e "     메타데이터만 기록 (URL, HTTP Method, 응답 코드, 사용자, 시간)."
    echo -e "     요청/응답 본문 없음. 로그 용량 최소."
    echo ""
    echo -e "  ${GREEN}2)${NC} WriteRequestBodies  ${YELLOW}[권장]${NC}"
    echo -e "     쓰기 요청(create/update/patch/delete) 본문 기록."
    echo -e "     감사 목적으로 충분하며 읽기 요청 본문은 제외."
    echo ""
    echo -e "  ${GREEN}3)${NC} AllRequestBodies"
    echo -e "     모든 요청·응답 본문 기록. 가장 상세하나 로그 용량 대폭 증가."
    echo -e "     민감 정보(Secret 값 등) 포함 가능 — 주의 필요."
    echo ""
    echo -e "  ${GREEN}4)${NC} None"
    echo -e "     Audit 로그 비활성화. ${RED}보안 권장사항에 맞지 않습니다.${NC}"
    echo ""
    read -r -p "  선택 [1-4, 기본값: 2]: " choice
    choice="${choice:-2}"

    case "$choice" in
        1) AUDIT_PROFILE="Default" ;;
        2) AUDIT_PROFILE="WriteRequestBodies" ;;
        3) AUDIT_PROFILE="AllRequestBodies" ;;
        4) AUDIT_PROFILE="None" ;;
        *)
            print_error "1~4 사이의 값을 입력하세요."
            exit 1
            ;;
    esac
    print_ok "선택: Audit Profile = ${AUDIT_PROFILE}"
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

    # OpenShift Logging Operator 확인
    if [ "${LOGGING_INSTALLED:-false}" = "true" ]; then
        HAS_LOGGING=true
        print_ok "OpenShift Logging Operator 확인"
    else
        HAS_LOGGING=false
        print_warn "OpenShift Logging Operator 미설치 → 건너뜁니다."
        print_warn "  설치 가이드: 00-operator/"
        exit 77
    fi

    # Loki Operator 확인
    if [ "${LOKI_INSTALLED:-false}" = "true" ]; then
        HAS_LOKI=true
        print_ok "Loki Operator 확인"
    else
        HAS_LOKI=false
        print_warn "Loki Operator 미설치 → LokiStack 생성을 건너뜁니다."
        if [ "$HAS_LOGGING" = "true" ]; then
            print_warn "  → ClusterLogForwarder는 Loki 없이 기본 출력(default)만 사용합니다."
        fi
    fi

    # Logging 버전 감지 (v6에서 ClusterLogging CRD 제거됨)
    if ! oc get crd clusterloggings.logging.openshift.io &>/dev/null; then
        LOGGING_V6=true
        print_ok "OpenShift Logging v6 감지 (observability.openshift.io/v1 사용)"
    else
        LOGGING_V6=false
        print_ok "OpenShift Logging v5 감지 (logging.openshift.io/v1 사용)"
    fi
}

# =============================================================================
# Step 1: APIServer Audit Policy 설정
# =============================================================================
step_audit_policy() {
    print_step "1/5  APIServer Audit Policy 설정 (프로필: ${AUDIT_PROFILE})"

    local current
    current=$(oc get apiserver cluster -o jsonpath='{.spec.audit.profile}' 2>/dev/null || echo "")
    if [ "${current}" = "${AUDIT_PROFILE}" ]; then
        print_ok "이미 동일한 프로필이 적용되어 있습니다 (${AUDIT_PROFILE}) — 건너뜁니다."
        return
    fi
    [ -n "$current" ] && print_info "현재 프로필: ${current} → 변경: ${AUDIT_PROFILE}"

    cat > ./audit-policy.yaml" <<EOF
apiVersion: config.openshift.io/v1
kind: APIServer
metadata:
  name: cluster
spec:
  audit:
    profile: ${AUDIT_PROFILE}
EOF

    confirm_and_apply ./audit-policy.yaml"
    print_ok "Audit Policy 적용 완료"
    print_info "kube-apiserver 롤아웃에 수분이 소요될 수 있습니다."
    print_info "  확인: oc get co kube-apiserver"
}

# =============================================================================
# Step 2: openshift-logging 네임스페이스 확인
# =============================================================================
step_namespace() {
    print_step "2/5  openshift-logging 네임스페이스 확인"

    if oc get namespace "${LOGGING_NS}" &>/dev/null; then
        print_ok "네임스페이스 ${LOGGING_NS} 존재"
    else
        print_info "네임스페이스 ${LOGGING_NS} 생성..."
        oc new-project "${LOGGING_NS}" >/dev/null 2>&1 || true
        print_ok "네임스페이스 ${LOGGING_NS} 생성 완료"
    fi
}

# =============================================================================
# Step 3: ClusterLogging 인스턴스 생성
# =============================================================================
step_cluster_logging() {
    print_step "3/5  ClusterLogging 인스턴스 생성"

    if [ "$LOGGING_V6" = "true" ]; then
        print_info "Logging v6 — ClusterLogging CR 없음, 건너뜁니다."
        return
    fi

    if oc get clusterlogging "${CL_NAME}" -n "${LOGGING_NS}" &>/dev/null; then
        print_ok "ClusterLogging '${CL_NAME}' 이미 존재합니다 — 건너뜁니다."
        return
    fi

    local log_store_type="lokistack"
    local log_store_block=""

    if [ "$HAS_LOKI" = "true" ]; then
        log_store_block="  logStore:
    type: lokistack
    lokiStack:
      name: ${LOKI_NAME}
    retentionPolicy:
      application:
        maxAge: 7d
      audit:
        maxAge: 30d
      infrastructure:
        maxAge: 7d"
    else
        # Loki 없을 경우 logStore 블록 생략 (Vector만 수집)
        log_store_block="  # logStore: Loki Operator 미설치로 생략"
    fi

    cat > ./cluster-logging.yaml" <<EOF
apiVersion: logging.openshift.io/v1
kind: ClusterLogging
metadata:
  name: ${CL_NAME}
  namespace: ${LOGGING_NS}
spec:
  managementState: Managed
${log_store_block}
  collection:
    type: vector
EOF

    confirm_and_apply ./cluster-logging.yaml"
    print_ok "ClusterLogging '${CL_NAME}' 생성 완료"
}

# =============================================================================
# Step 4: LokiStack + S3 Secret 생성 (Loki Operator 설치 시)
# =============================================================================
step_loki_secret() {
    if oc get secret logging-loki-s3 -n "${LOGGING_NS}" &>/dev/null; then
        print_ok "S3 Secret 'logging-loki-s3' 이미 존재합니다."
        return
    fi

    local s3_endpoint s3_bucket s3_access_key s3_secret_key s3_region s3_backend

    if [ "${ODF_INSTALLED:-false}" = "true" ] && [ -n "${ODF_S3_ENDPOINT:-}" ]; then
        s3_backend="ODF MCG"
        s3_endpoint="${ODF_S3_ENDPOINT}"
        s3_bucket="${ODF_S3_BUCKET:-loki}"
        s3_access_key="${ODF_S3_ACCESS_KEY}"
        s3_secret_key="${ODF_S3_SECRET_KEY}"
        s3_region="${ODF_S3_REGION:-us-east-1}"
    elif [ "${MINIO_INSTALLED:-false}" = "true" ] && [ -n "${MINIO_ENDPOINT:-}" ]; then
        s3_backend="MinIO"
        s3_endpoint="${MINIO_ENDPOINT}"
        s3_bucket="${MINIO_BUCKET:-loki}"
        s3_access_key="${MINIO_ACCESS_KEY}"
        s3_secret_key="${MINIO_SECRET_KEY}"
        s3_region="us-east-1"
    else
        print_error "S3 백엔드를 찾을 수 없습니다."
        print_warn "  ODF_INSTALLED=${ODF_INSTALLED:-false}, MINIO_INSTALLED=${MINIO_INSTALLED:-false}"
        print_warn "  env.conf 에서 ODF_S3_* 또는 MINIO_* 변수를 확인하세요."
        exit 1
    fi

    print_info "${s3_backend} S3 Secret 생성 중..."
    oc create secret generic logging-loki-s3 \
        -n "${LOGGING_NS}" \
        --from-literal=access_key_id="${s3_access_key}" \
        --from-literal=access_key_secret="${s3_secret_key}" \
        --from-literal=bucketnames="${s3_bucket}" \
        --from-literal=endpoint="${s3_endpoint}" \
        --from-literal=region="${s3_region}"
    print_ok "S3 Secret 'logging-loki-s3' 생성 완료 (${s3_backend})"
    print_info "  endpoint : ${s3_endpoint}"
    print_info "  bucket   : ${s3_bucket}"
}

step_loki_stack() {
    print_step "4/5  LokiStack 생성"

    if oc get lokistack "${LOKI_NAME}" -n "${LOGGING_NS}" &>/dev/null; then
        print_ok "LokiStack '${LOKI_NAME}' 이미 존재합니다 — 건너뜁니다."
        return
    fi

    step_loki_secret

    cat > ./loki-stack.yaml" <<EOF
apiVersion: loki.grafana.com/v1
kind: LokiStack
metadata:
  name: ${LOKI_NAME}
  namespace: ${LOGGING_NS}
spec:
  size: 1x.small
  storage:
    schemas:
      - version: v13
        effectiveDate: "2024-01-01"
    secret:
      name: logging-loki-s3
      type: s3
  storageClassName: ${STORAGE_CLASS}
  tenants:
    mode: openshift-logging
EOF

    confirm_and_apply ./loki-stack.yaml"

    print_info "LokiStack 준비 대기 중 (최대 5분)..."
    local retries=30 i=0
    while [ "$i" -lt "$retries" ]; do
        local phase
        phase=$(oc get lokistack "${LOKI_NAME}" -n "${LOGGING_NS}" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        if [ "$phase" = "True" ]; then
            print_ok "LokiStack '${LOKI_NAME}' Ready"
            break
        fi
        printf "  [%d/%d] 대기 중...\r" "$((i+1))" "$retries"
        sleep 10
        i=$((i+1))
    done
    echo ""
    [ "$i" -eq "$retries" ] && print_warn "LokiStack 준비 시간 초과. 상태 확인: oc get lokistack -n ${LOGGING_NS}"
}

# =============================================================================
# Step 5: ClusterLogForwarder (Audit 로그 포함)
# =============================================================================
step_log_forwarder() {
    print_step "5/5  ClusterLogForwarder 구성 (audit + infrastructure + application)"

    if oc get clusterlogforwarder "${CLF_NAME}" -n "${LOGGING_NS}" &>/dev/null; then
        print_warn "ClusterLogForwarder '${CLF_NAME}' 이미 존재합니다."
        read -r -p "기존 설정을 덮어쓰시겠습니까? [y/N]: " overwrite
        [[ "$overwrite" != "y" && "$overwrite" != "Y" ]] && { print_info "건너뜁니다."; return; }
    fi

    if [ "$LOGGING_V6" = "true" ]; then
        # v6: observability.openshift.io/v1, ServiceAccount 필요
        if ! oc get serviceaccount collector -n "${LOGGING_NS}" &>/dev/null; then
            oc create serviceaccount collector -n "${LOGGING_NS}"
            print_ok "ServiceAccount collector 생성"
        fi
        for role in collect-application-logs collect-infrastructure-logs collect-audit-logs; do
            oc adm policy add-cluster-role-to-user "${role}" \
                -z collector -n "${LOGGING_NS}" 2>/dev/null || true
        done
        print_ok "collector ServiceAccount 권한 부여"

        local output_section
        if [ "$HAS_LOKI" = "true" ]; then
            output_section="  outputs:
    - name: loki-storage
      type: lokiStack
      lokiStack:
        target:
          name: ${LOKI_NAME}
          namespace: ${LOGGING_NS}
        authentication:
          token:
            from: serviceAccount
  pipelines:
    - name: all-to-loki
      inputRefs:
        - application
        - infrastructure
        - audit
      outputRefs:
        - loki-storage"
        else
            output_section="  pipelines:
    - name: all-to-default
      inputRefs:
        - application
        - infrastructure
        - audit
      outputRefs:
        - default"
        fi

        cat > ./cluster-log-forwarder.yaml" <<EOF
apiVersion: observability.openshift.io/v1
kind: ClusterLogForwarder
metadata:
  name: ${CLF_NAME}
  namespace: ${LOGGING_NS}
spec:
  serviceAccount:
    name: collector
${output_section}
EOF
    else
        # v5: logging.openshift.io/v1
        local output_section
        if [ "$HAS_LOKI" = "true" ]; then
            output_section="  outputs:
    - name: loki-storage
      type: lokiStack
      lokiStack:
        target:
          name: ${LOKI_NAME}
          namespace: ${LOGGING_NS}
        authentication:
          token:
            from: serviceAccount
  pipelines:
    - name: all-to-loki
      inputRefs:
        - application
        - infrastructure
        - audit
      outputRefs:
        - loki-storage"
        else
            output_section="  pipelines:
    - name: all-to-default
      inputRefs:
        - application
        - infrastructure
        - audit
      outputRefs:
        - default"
        fi

        cat > ./cluster-log-forwarder.yaml" <<EOF
apiVersion: logging.openshift.io/v1
kind: ClusterLogForwarder
metadata:
  name: ${CLF_NAME}
  namespace: ${LOGGING_NS}
spec:
${output_section}
EOF
    fi

    confirm_and_apply ./cluster-log-forwarder.yaml"
    print_ok "ClusterLogForwarder '${CLF_NAME}' 적용 완료"
}

# =============================================================================
# 상태 확인
# =============================================================================
step_verify() {
    print_step "상태 확인"

    echo ""
    echo -e "${CYAN}  [ APIServer Audit Policy ]${NC}"
    oc get apiserver cluster -o jsonpath='    profile: {.spec.audit.profile}{"\n"}' 2>/dev/null || \
        echo "    (확인 불가)"

    echo ""
    echo -e "${CYAN}  [ kube-apiserver Cluster Operator ]${NC}"
    oc get co kube-apiserver 2>/dev/null | \
        awk 'NR==1{printf "    %-30s %-10s %-12s %-12s\n",$1,$2,$3,$4} NR>1{printf "    %-30s %-10s %-12s %-12s\n",$1,$2,$3,$4}' || true

    if [ "$HAS_LOGGING" = "true" ]; then
        echo ""
        echo -e "${CYAN}  [ ClusterLogging ]${NC}"
        oc get clusterlogging -n "${LOGGING_NS}" 2>/dev/null | \
            awk '{printf "    %s\n", $0}' || echo "    (없음)"

        echo ""
        echo -e "${CYAN}  [ ClusterLogForwarder ]${NC}"
        oc get clusterlogforwarder -n "${LOGGING_NS}" 2>/dev/null | \
            awk '{printf "    %s\n", $0}' || echo "    (없음)"

        if [ "$HAS_LOKI" = "true" ]; then
            echo ""
            echo -e "${CYAN}  [ LokiStack ]${NC}"
            oc get lokistack -n "${LOGGING_NS}" 2>/dev/null | \
                awk '{printf "    %s\n", $0}' || echo "    (없음)"
        fi

        echo ""
        echo -e "${CYAN}  [ Collector Pods ]${NC}"
        oc get pods -n "${LOGGING_NS}" -l component=collector 2>/dev/null | \
            awk '{printf "    %s\n", $0}' || echo "    (없음)"
    fi

    echo ""
    print_info "Audit 로그 실시간 확인 (예시):"
    echo -e "    ${CYAN}oc adm node-logs --role=master --path=kube-apiserver/ | grep audit${NC}"
    if [ "$HAS_LOGGING" = "true" ]; then
        echo -e "    ${CYAN}oc logs -n ${LOGGING_NS} -l component=collector --tail=20${NC}"
    fi
    echo ""
}

# =============================================================================
# Cleanup
# =============================================================================
cleanup() {
    print_step "--cleanup: 19-logging 리소스 삭제"
    local _logging_ns="openshift-logging"
    oc delete clusterlogforwarder --all -n "$_logging_ns" --ignore-not-found 2>/dev/null || true
    oc delete clusterlogging instance -n "$_logging_ns" --ignore-not-found 2>/dev/null || true
    oc delete lokistack logging-loki -n "$_logging_ns" --ignore-not-found 2>/dev/null || true
    oc delete secret logging-loki-s3 -n "$_logging_ns" --ignore-not-found 2>/dev/null || true
    oc delete project "$_logging_ns" --ignore-not-found 2>/dev/null || true
    print_ok "19-logging 리소스 삭제 완료"
}

# =============================================================================
# main
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  OpenShift Audit Logging 구성${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    choose_audit_profile
    preflight

    step_audit_policy

    if [ "$HAS_LOGGING" = "true" ]; then
        step_namespace
        step_cluster_logging
        if [ "$HAS_LOKI" = "true" ]; then
            step_loki_stack
        else
            print_step "4/5  LokiStack 생성"
            print_warn "Loki Operator 미설치 — 건너뜁니다."
        fi
        step_log_forwarder
    else
        print_step "3/5  ClusterLogging"
        print_warn "OpenShift Logging Operator 미설치 — 건너뜁니다."
        print_step "4/5  LokiStack"
        print_warn "OpenShift Logging Operator 미설치 — 건너뜁니다."
        print_step "5/5  ClusterLogForwarder"
        print_warn "OpenShift Logging Operator 미설치 — 건너뜁니다."
    fi

    step_verify

    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  Audit Logging 구성 완료${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

[ "${1:-}" = "--cleanup" ] && { cleanup; exit 0; }
main "$@"
