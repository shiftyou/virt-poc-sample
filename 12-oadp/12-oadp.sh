#!/bin/bash
# =============================================================================
# 12-oadp.sh
#
# OADP 실습 환경 구성
#   1. poc-oadp 네임스페이스 생성
#   2. MinIO 자격증명 Secret 생성
#   3. DataProtectionApplication 배포
#   4. BackupStorageLocation 확인
#
# 사용법: ./11-oadp.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

NS="poc-oadp"
OADP_NS="openshift-adp"

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

preflight() {
    print_step "사전 확인"

    if ! oc whoami &>/dev/null; then
        print_error "OpenShift 에 로그인되어 있지 않습니다."
        exit 1
    fi
    print_ok "클러스터 접속: $(oc whoami) @ $(oc whoami --show-server)"

    if [ "${OADP_INSTALLED:-false}" != "true" ]; then
        print_warn "OADP Operator 미설치 → 건너뜁니다."
        print_warn "  설치 가이드: 00-operator/oadp-operator.md"
        exit 77
    fi
    print_ok "OADP Operator 확인"

    print_info "  MinIO Endpoint: ${MINIO_ENDPOINT:-미설정}"
    print_info "  MinIO Bucket  : ${MINIO_BUCKET:-미설정}"
}

step_namespace() {
    print_step "1/4  네임스페이스 생성 (${NS})"

    if oc get namespace "$NS" &>/dev/null; then
        print_ok "네임스페이스 $NS 이미 존재 — 스킵"
    else
        oc new-project "$NS" > /dev/null
        print_ok "네임스페이스 $NS 생성 완료"
    fi
}

step_credentials() {
    print_step "2/4  MinIO 자격증명 Secret 생성"

    cat > cloud-credentials.txt <<EOF
[default]
aws_access_key_id=${MINIO_ACCESS_KEY:-minio}
aws_secret_access_key=${MINIO_SECRET_KEY:-minio123}
EOF

    oc create secret generic cloud-credentials \
        -n "$OADP_NS" \
        --from-file=cloud=cloud-credentials.txt \
        --dry-run=client -o yaml | oc apply -f -
    rm -f cloud-credentials.txt
    print_ok "cloud-credentials Secret 생성 완료"
}

step_dpa() {
    print_step "3/4  DataProtectionApplication 배포"

    if oc get dpa poc-dpa -n "$OADP_NS" &>/dev/null; then
        print_ok "DataProtectionApplication poc-dpa 이미 존재 — 스킵"
        return
    fi

    cat > poc-dpa.yaml <<EOF
apiVersion: oadp.openshift.io/v1alpha1
kind: DataProtectionApplication
metadata:
  name: poc-dpa
  namespace: ${OADP_NS}
spec:
  configuration:
    velero:
      defaultPlugins:
        - openshift
        - aws
        - kubevirt
      resourceTimeout: 10m
    nodeAgent:
      enable: true
      uploaderType: kopia
  backupLocations:
    - name: default
      velero:
        provider: aws
        default: true
        objectStorage:
          bucket: ${MINIO_BUCKET:-velero}
          prefix: velero
        config:
          region: minio
          s3ForcePathStyle: "true"
          s3Url: ${MINIO_ENDPOINT:-http://minio.poc-minio.svc.cluster.local:9000}
          insecureSkipTLSVerify: "true"
        credential:
          key: cloud
          name: cloud-credentials
  snapshotLocations:
    - name: default
      velero:
        provider: aws
        config:
          region: minio
EOF
    oc apply -f poc-dpa.yaml
    print_ok "DataProtectionApplication poc-dpa 배포 완료"
}

step_verify() {
    print_step "4/4  BackupStorageLocation 확인"

    print_info "BackupStorageLocation 준비 대기 중..."
    local retries=12
    local i=0
    while [ $i -lt $retries ]; do
        local phase
        phase=$(oc get backupstoragelocation default \
            -n "$OADP_NS" \
            -o jsonpath='{.status.phase}' 2>/dev/null || true)
        if [ "$phase" = "Available" ]; then
            print_ok "BackupStorageLocation 상태: Available"
            break
        fi
        printf "  [%d/%d] 대기 중... (%s)\r" "$((i+1))" "$retries" "${phase:-Pending}"
        sleep 10
        i=$((i+1))
    done
    echo ""

    if [ $i -eq $retries ]; then
        print_warn "BackupStorageLocation 준비 시간 초과. MinIO 연결을 확인하세요."
        print_info "  MinIO Endpoint: ${MINIO_ENDPOINT:-미설정}"
        print_info "  oc describe backupstoragelocation default -n ${OADP_NS}"
    fi
}

print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  완료! OADP 실습 환경이 준비되었습니다.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  BackupStorageLocation 확인:"
    echo -e "    ${CYAN}oc get backupstoragelocation -n ${OADP_NS}${NC}"
    echo ""
    echo -e "  VM 백업 실행:"
    echo -e "    ${CYAN}oc create -f - <<EOF${NC}"
    echo -e "    ${CYAN}apiVersion: velero.io/v1${NC}"
    echo -e "    ${CYAN}kind: Backup${NC}"
    echo -e "    ${CYAN}metadata:${NC}"
    echo -e "    ${CYAN}  name: poc-vm-backup${NC}"
    echo -e "    ${CYAN}  namespace: ${OADP_NS}${NC}"
    echo -e "    ${CYAN}spec:${NC}"
    echo -e "    ${CYAN}  includedNamespaces: [${NS}]${NC}"
    echo -e "    ${CYAN}  storageLocation: default${NC}"
    echo -e "    ${CYAN}  snapshotMoveData: true${NC}"
    echo -e "    ${CYAN}EOF${NC}"
    echo ""
    echo -e "  자세한 내용: 14-oadp.md 참조"
    echo ""
}

main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  OADP 실습 환경 구성${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    preflight
    step_namespace
    step_credentials
    step_dpa
    step_verify
    print_summary
}

main
