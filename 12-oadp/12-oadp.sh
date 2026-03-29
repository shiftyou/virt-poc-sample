#!/bin/bash
# =============================================================================
# 12-oadp.sh
#
# OADP 실습 환경 구성
#   1. OADP Operator 네임스페이스 확인 (기본: openshift-adp)
#   2. ObjectBucketClaim 생성 및 버킷 정보 취득 (ODF 백엔드 시)
#   3. cloud-credentials Secret 생성
#   4. VolumeSnapshotClass YAML 생성 (CSI 스냅샷용, 스토리지 환경에 맞게 적용)
#   5. DataProtectionApplication 배포
#   6. BackupStorageLocation 확인
#
# 실행 조건:
#   - OADP Operator 설치 필수 (기본 네임스페이스: openshift-adp)
#   - 백엔드: MinIO Operator 설치 + 설정 완료, 또는 ODF Operator 설치
#
# 사용법: ./12-oadp.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

# openshift-adp 가 있으면 우선 사용, 없으면 setup.sh 에서 감지한 OADP_NS 사용
if oc get namespace "openshift-adp" &>/dev/null 2>&1; then
    NS="openshift-adp"
else
    NS="${OADP_NS:-openshift-adp}"
fi

# 사용할 백엔드: minio | odf (preflight 에서 결정)
BACKEND=""

# 통합 S3 변수 (preflight 에서 백엔드에 따라 설정)
S3_ENDPOINT=""
S3_BUCKET=""
S3_ACCESS_KEY=""
S3_SECRET_KEY=""
S3_REGION=""

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

    # OADP Operator 필수
    if [ "${OADP_INSTALLED:-false}" != "true" ]; then
        print_warn "OADP Operator 미설치 → 건너뜁니다."
        print_warn "  설치 가이드: 00-operator/oadp-operator.md"
        exit 77
    fi
    print_ok "OADP Operator 확인 (ns: ${NS})"

    # 백엔드 결정: MinIO 우선, 없으면 ODF
    local minio_ok=false
    local odf_ok=false

    [ "${MINIO_INSTALLED:-false}" = "true" ] && [ -n "${MINIO_ENDPOINT:-}" ] && minio_ok=true
    [ "${ODF_INSTALLED:-false}"   = "true" ] && odf_ok=true

    if [ "$minio_ok" = "false" ] && [ "$odf_ok" = "false" ]; then
        print_warn "MinIO 설정도 없고 ODF Operator 도 미설치 → 건너뜁니다."
        print_warn "  MinIO : MinIO Operator 설치 후 setup.sh 재실행"
        print_warn "  ODF   : ODF Operator 설치 후 setup.sh 재실행"
        exit 77
    fi

    if [ "$minio_ok" = "true" ]; then
        BACKEND="minio"
        S3_ENDPOINT="${MINIO_ENDPOINT}"
        S3_BUCKET="${MINIO_BUCKET:-velero}"
        S3_ACCESS_KEY="${MINIO_ACCESS_KEY:-minio}"
        S3_SECRET_KEY="${MINIO_SECRET_KEY:-minio123}"
        S3_REGION="minio"
    else
        BACKEND="odf"
        S3_ENDPOINT="${ODF_S3_ENDPOINT}"
        S3_BUCKET="${ODF_S3_BUCKET:-velero}"
        S3_ACCESS_KEY="${ODF_S3_ACCESS_KEY:-}"
        S3_SECRET_KEY="${ODF_S3_SECRET_KEY:-}"
        S3_REGION="localstorage"
    fi

    print_ok "백엔드: ${BACKEND}"
    print_info "  S3 Endpoint : ${S3_ENDPOINT}"
    print_info "  S3 Bucket   : ${S3_BUCKET}"
    print_info "  S3 Region   : ${S3_REGION}"
    print_info "  S3 AccessKey: ${S3_ACCESS_KEY}"
}

# =============================================================================
# 1단계: 네임스페이스 확인 (OADP Operator 설치 네임스페이스)
# =============================================================================
step_namespace() {
    print_step "1/6  네임스페이스 확인 (${NS})"

    if oc get namespace "$NS" &>/dev/null; then
        print_ok "네임스페이스 $NS 확인 완료"
    else
        print_error "네임스페이스 $NS 없음 — OADP Operator 가 설치되어 있는지 확인하세요."
        print_error "  설치 가이드: 00-operator/oadp-operator.md"
        exit 1
    fi
}

# =============================================================================
# 2단계: ObjectBucketClaim 생성 및 버킷 정보 취득 (ODF 백엔드 전용)
# =============================================================================
step_obc() {
    if [ "$BACKEND" != "odf" ]; then
        print_step "2/6  OBC — MinIO 백엔드이므로 스킵"
        return
    fi

    print_step "2/6  ObjectBucketClaim 생성 (ns: ${NS})"

    # NooBaa StorageClass 자동 감지
    local obc_sc
    obc_sc=$(oc get storageclass -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | \
        tr ' ' '\n' | grep -i "noobaa" | head -1 || true)
    if [ -z "$obc_sc" ]; then
        obc_sc="openshift-storage.noobaa.io"
        print_warn "NooBaa StorageClass 자동 감지 실패 → 기본값: ${obc_sc}"
    else
        print_info "OBC StorageClass: ${obc_sc}"
    fi

    if oc get obc obc-backups -n "$NS" &>/dev/null; then
        print_ok "ObjectBucketClaim obc-backups 이미 존재 — 스킵"
    else
        cat > obc-backups.yaml <<EOF
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata:
  name: obc-backups
  namespace: ${NS}
spec:
  generateBucketName: backups
  storageClassName: ${obc_sc}
EOF
        echo "생성된 파일: obc-backups.yaml"
        oc apply -f obc-backups.yaml
        print_ok "ObjectBucketClaim obc-backups 생성 완료 → ns: ${NS}"
    fi

    # Bound 대기
    print_info "OBC Bound 대기 중..."
    local retries=12
    local i=0
    while [ $i -lt $retries ]; do
        local phase
        phase=$(oc get obc obc-backups -n "$NS" \
            -o jsonpath='{.status.phase}' 2>/dev/null || true)
        if [ "$phase" = "Bound" ]; then
            print_ok "OBC 상태: Bound"
            break
        fi
        printf "  [%d/%d] 대기 중... (%s)\r" "$((i+1))" "$retries" "${phase:-Pending}"
        sleep 5
        i=$((i+1))
    done
    echo ""

    if [ $i -eq $retries ]; then
        print_error "OBC Bound 시간 초과. ODF/NooBaa 상태를 확인하세요."
        exit 1
    fi

    # ConfigMap 에서 버킷명·엔드포인트 취득
    S3_BUCKET=$(oc get cm obc-backups -n "$NS" \
        -o jsonpath='{.data.BUCKET_NAME}' 2>/dev/null || true)
    local bucket_host bucket_port
    bucket_host=$(oc get cm obc-backups -n "$NS" \
        -o jsonpath='{.data.BUCKET_HOST}' 2>/dev/null || true)
    bucket_port=$(oc get cm obc-backups -n "$NS" \
        -o jsonpath='{.data.BUCKET_PORT}' 2>/dev/null || echo "80")

    if [ -n "$bucket_host" ]; then
        if [ "$bucket_port" = "80" ] || [ -z "$bucket_port" ]; then
            S3_ENDPOINT="http://${bucket_host}"
        else
            S3_ENDPOINT="http://${bucket_host}:${bucket_port}"
        fi
    fi

    # Secret 에서 자격증명 취득
    S3_ACCESS_KEY=$(oc get secret obc-backups -n "$NS" \
        -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' 2>/dev/null | base64 -d || true)
    S3_SECRET_KEY=$(oc get secret obc-backups -n "$NS" \
        -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' 2>/dev/null | base64 -d || true)

    print_ok "OBC 버킷 정보 취득 완료"
    print_info "  Bucket  : ${S3_BUCKET}"
    print_info "  Endpoint: ${S3_ENDPOINT}"
}

# =============================================================================
# 3단계: cloud-credentials Secret 생성 (OADP Operator 네임스페이스)
# =============================================================================
step_credentials() {
    print_step "3/6  cloud-credentials Secret 생성 (백엔드: ${BACKEND}, ns: ${NS})"

    cat > cloud-credentials-secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cloud-credentials
  namespace: ${NS}
stringData:
  cloud: |
    [default]
    aws_access_key_id=${S3_ACCESS_KEY}
    aws_secret_access_key=${S3_SECRET_KEY}
EOF
    echo "생성된 파일: cloud-credentials-secret.yaml"
    oc apply -f cloud-credentials-secret.yaml
    print_ok "cloud-credentials Secret 생성 완료 → ns: ${NS}"
}

# =============================================================================
# 3단계: VolumeSnapshotClass YAML 생성 (CSI 스냅샷용)
# =============================================================================
step_volumesnapshotclass() {
    print_step "4/6  VolumeSnapshotClass YAML 생성"

    # 클러스터의 CSI 드라이버 자동 감지
    local csi_driver
    csi_driver=$(oc get csidrivers -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | \
        tr ' ' '\n' | grep -v "^kubernetes\|^csi-snapshot\|^file" | head -1 || true)

    if [ -z "$csi_driver" ]; then
        csi_driver="your.csi.driver.com"
        print_warn "CSI 드라이버 자동 감지 실패 → 기본값: ${csi_driver}"
        print_warn "  실제 드라이버명으로 수정 후 적용하세요: oc get csidrivers"
    else
        print_info "CSI 드라이버 감지: ${csi_driver}"
    fi

    cat > volumesnapshotclass.yaml <<EOF
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: poc-volumesnapshotclass
  labels:
    velero.io/csi-volumesnapshot-class: "true"
driver: ${csi_driver}
deletionPolicy: Delete
EOF
    echo "생성된 파일: volumesnapshotclass.yaml"
    print_info "CSI 스냅샷 사용 시 아래 명령으로 적용하세요:"
    echo -e "    ${CYAN}oc apply -f volumesnapshotclass.yaml${NC}"
}

# =============================================================================
# 4단계: DataProtectionApplication 배포 (OADP Operator 네임스페이스)
# =============================================================================
step_dpa() {
    print_step "5/6  DataProtectionApplication 배포 (백엔드: ${BACKEND}, ns: ${NS})"

    if oc get dpa poc-dpa -n "$NS" &>/dev/null; then
        print_ok "DataProtectionApplication poc-dpa 이미 존재 — 스킵"
        return
    fi

    cat > poc-dpa.yaml <<EOF
apiVersion: oadp.openshift.io/v1alpha1
kind: DataProtectionApplication
metadata:
  name: poc-dpa
  namespace: ${NS}
spec:
  configuration:
    velero:
      defaultPlugins:
        - csi
        - openshift
        - aws
        - kubevirt
      disableFsBackup: false
      featureFlags:
        - EnableCSI
  logFormat: text
  backupLocations:
    - velero:
        provider: aws
        default: true
        objectStorage:
          bucket: ${S3_BUCKET}
          prefix: velero
        config:
          profile: default
          region: ${S3_REGION}
          s3ForcePathStyle: "true"
          s3Url: ${S3_ENDPOINT}
          checksumAlgorithm: ""
        credential:
          key: cloud
          name: cloud-credentials
EOF
    echo "생성된 파일: poc-dpa.yaml"
    oc apply -f poc-dpa.yaml
    print_ok "DataProtectionApplication poc-dpa 배포 완료 → ns: ${NS}"
}

# =============================================================================
# 5단계: BackupStorageLocation 확인
# =============================================================================
step_verify() {
    print_step "6/6  BackupStorageLocation 확인 (ns: ${NS})"

    print_info "BackupStorageLocation 준비 대기 중..."
    local retries=12
    local i=0
    while [ $i -lt $retries ]; do
        local phase
        phase=$(oc get backupstoragelocation -n "$NS" \
            -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
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
        print_warn "BackupStorageLocation 준비 시간 초과. 백엔드 연결을 확인하세요."
        print_info "  oc describe backupstoragelocation -n ${NS}"
    fi
}

print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  완료! OADP 실습 환경이 준비되었습니다.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  백엔드 : ${BACKEND}"
    echo ""
    echo -e "  BackupStorageLocation 확인:"
    echo -e "    ${CYAN}oc get backupstoragelocation -n ${NS}${NC}"
    echo ""
    echo -e "  VM 백업 실행 (ns: ${NS}):"
    echo -e "    ${CYAN}oc create -f - <<EOF${NC}"
    echo -e "    ${CYAN}apiVersion: velero.io/v1${NC}"
    echo -e "    ${CYAN}kind: Backup${NC}"
    echo -e "    ${CYAN}metadata:${NC}"
    echo -e "    ${CYAN}  name: poc-vm-backup${NC}"
    echo -e "    ${CYAN}  namespace: ${NS}${NC}"
    echo -e "    ${CYAN}spec:${NC}"
    echo -e "    ${CYAN}  includedNamespaces: [${NS}]${NC}"
    echo -e "    ${CYAN}  storageLocation: default${NC}"
    echo -e "    ${CYAN}  snapshotVolumes: true${NC}"
    echo -e "    ${CYAN}EOF${NC}"
    echo ""
    echo -e "  VM 복원 실행 (ns: ${NS}):"
    echo -e "    ${CYAN}oc create -f - <<EOF${NC}"
    echo -e "    ${CYAN}apiVersion: velero.io/v1${NC}"
    echo -e "    ${CYAN}kind: Restore${NC}"
    echo -e "    ${CYAN}metadata:${NC}"
    echo -e "    ${CYAN}  name: poc-vm-restore${NC}"
    echo -e "    ${CYAN}  namespace: ${NS}${NC}"
    echo -e "    ${CYAN}spec:${NC}"
    echo -e "    ${CYAN}  backupName: poc-vm-backup${NC}"
    echo -e "    ${CYAN}  includedNamespaces: [${NS}]${NC}"
    echo -e "    ${CYAN}EOF${NC}"
    echo ""
    echo -e "  자세한 내용: 12-oadp.md 참조"
    echo ""
}

main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  OADP 실습 환경 구성${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    preflight
    step_namespace
    step_obc
    step_credentials
    step_volumesnapshotclass
    step_dpa
    step_verify
    print_summary
}

main
