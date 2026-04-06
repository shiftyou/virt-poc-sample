#!/bin/bash
# =============================================================================
# 13-oadp.sh
#
# OADP 실습 환경 구성
#   1. OADP Operator 네임스페이스 확인 (기본: openshift-adp)
#   2. ObjectBucketClaim 생성 및 버킷/자격증명 취득 (ODF 백엔드 전용)
#   3. cloud-credentials Secret 생성
#   4. VolumeSnapshotClass YAML 생성 (CSI 스냅샷용, 스토리지 환경에 맞게 적용)
#   5. DataProtectionApplication 배포
#   6. BackupStorageLocation 확인
#   7. poc-oadp 네임스페이스 생성
#   8. poc-oadp VM 생성 (poc DataSource 사용)
#   9. Backup CR 생성 (poc-oadp 백업) + Restore YAML 생성 (미적용)
#
# 실행 조건:
#   - OADP Operator 설치 필수 (기본 네임스페이스: openshift-adp)
#   - 백엔드: MinIO 커뮤니티 버전 배포 + 설정 완료, 또는 ODF Operator 설치
#
# 사용법: ./13-oadp.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

NS="${OADP_NS:-openshift-adp}"

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

# YAML 미리보기 후 적용
confirm_and_apply() {
    local file="$1"
    echo ""
    print_info "적용할 YAML:"
    echo "────────────────────────────────────────"
    cat "$file"
    echo "────────────────────────────────────────"
    oc apply -f "$file"
}

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

    # S3 초기값 결정: MinIO 우선, 없으면 ODF, 없으면 빈값(직접 입력)
    if [ "${MINIO_INSTALLED:-false}" = "true" ] && [ -n "${MINIO_ENDPOINT:-}" ]; then
        BACKEND="minio"
        S3_ENDPOINT="${MINIO_ENDPOINT}"
        S3_BUCKET="${OADP_S3_BUCKET:-${MINIO_BUCKET:-velero}}"
        S3_ACCESS_KEY="${MINIO_ACCESS_KEY:-}"
        S3_SECRET_KEY="${MINIO_SECRET_KEY:-}"
        S3_REGION="${OADP_S3_REGION:-us-east-1}"
    elif [ "${ODF_INSTALLED:-false}" = "true" ] && [ -n "${ODF_S3_ENDPOINT:-}" ]; then
        BACKEND="odf"
        S3_ENDPOINT="${ODF_S3_ENDPOINT}"
        S3_BUCKET="(OBC 자동 생성 — step_obc 에서 결정)"
        S3_ACCESS_KEY="${ODF_S3_ACCESS_KEY:-}"
        S3_SECRET_KEY="${ODF_S3_SECRET_KEY:-}"
        S3_REGION="${OADP_S3_REGION:-${ODF_S3_REGION:-us-east-1}}"
    else
        BACKEND="custom"
        S3_ENDPOINT="${OADP_S3_ENDPOINT:-}"
        S3_BUCKET="${OADP_S3_BUCKET:-velero}"
        S3_ACCESS_KEY="${OADP_S3_ACCESS_KEY:-}"
        S3_SECRET_KEY="${OADP_S3_SECRET_KEY:-}"
        S3_REGION="${OADP_S3_REGION:-us-east-1}"
        print_warn "Object Storage 자동 감지 실패 — 아래에서 직접 입력하세요."
    fi

    echo ""
    print_info "── Object Storage (S3) — OADP 백업용 ──"
    print_info "  백엔드      : ${BACKEND}"
    print_info "  S3 Endpoint : ${S3_ENDPOINT:-(미설정)}"
    print_info "  S3 Bucket   : ${S3_BUCKET}"
    print_info "  S3 Region   : ${S3_REGION}"
    print_info "  S3 AccessKey: ${S3_ACCESS_KEY:-(미설정)}"
    print_info "  S3 SecretKey: ****"
    echo ""
    read -r -p "  위 내용이 맞습니까? (Y/n): " _confirm
    if [[ "${_confirm:-}" =~ ^[Nn]$ ]]; then
        read -r -p "  S3 Endpoint  [${S3_ENDPOINT}]: " _input
        [ -n "$_input" ] && S3_ENDPOINT="$_input"
        read -r -p "  S3 Bucket    [${S3_BUCKET}]: " _input
        [ -n "$_input" ] && S3_BUCKET="$_input"
        read -r -p "  S3 Region    [${S3_REGION}]: " _input
        [ -n "$_input" ] && S3_REGION="$_input"
        read -r -p "  S3 AccessKey [${S3_ACCESS_KEY}]: " _input
        [ -n "$_input" ] && S3_ACCESS_KEY="$_input"
        read -r -s -p "  S3 SecretKey [****]: " _input
        echo ""
        [ -n "$_input" ] && S3_SECRET_KEY="$_input"
    fi

    if [ -z "${S3_ENDPOINT}" ] || [ -z "${S3_ACCESS_KEY}" ]; then
        print_error "S3 Endpoint 또는 AccessKey가 비어 있습니다."
        exit 1
    fi
    print_ok "Object Storage 설정 확인 완료 (백엔드: ${BACKEND}, bucket: ${S3_BUCKET})"
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
# 2단계: ObjectBucketClaim 생성 및 버킷/자격증명 취득 (ODF 백엔드 전용)
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

    # ConfigMap 에서 버킷명 취득
    # S3_ENDPOINT, S3_REGION 은 env.conf(ODF_S3_ENDPOINT/REGION) 값 유지
    S3_BUCKET=$(oc get cm obc-backups -n "$NS" \
        -o jsonpath='{.data.BUCKET_NAME}' 2>/dev/null || true)

    # Secret 에서 per-bucket 자격증명 취득 (noobaa-admin 대신)
    S3_ACCESS_KEY=$(oc get secret obc-backups -n "$NS" \
        -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' 2>/dev/null | base64 -d || true)
    S3_SECRET_KEY=$(oc get secret obc-backups -n "$NS" \
        -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' 2>/dev/null | base64 -d || true)

    print_ok "OBC 버킷/자격증명 취득 완료"
    print_info "  Bucket   : ${S3_BUCKET}"
    print_info "  Endpoint : ${S3_ENDPOINT}"
    print_info "  Region   : ${S3_REGION}"
    print_info "  AccessKey: ${S3_ACCESS_KEY}"
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
    confirm_and_apply cloud-credentials-secret.yaml
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
    nodeAgent:
      enable: true
      uploaderType: restic
    velero:
      defaultPlugins:
        - aws
        - openshift
        - kubevirt
        - csi
      disableFsBackup: false
  logFormat: text
  backupLocations:
    - velero:
        provider: aws
        default: true
        objectStorage:
          bucket: ${S3_BUCKET}
          prefix: oadp
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
    confirm_and_apply poc-dpa.yaml
    print_ok "DataProtectionApplication poc-dpa 배포 완료 → ns: ${NS}"
}

# =============================================================================
# 5단계: BackupStorageLocation 확인
# =============================================================================
step_verify() {
    print_step "6/6  BackupStorageLocation 확인 (ns: ${NS})"

    # 다른 DPA가 있으면 items[0]이 poc-dpa-1이 아닐 수 있으므로 이름 직접 지정
    local BSL_NAME="poc-dpa-1"

    echo ""
    # 네임스페이스에 다른 DPA/BSL이 있으면 경고
    local other_bsl
    other_bsl=$(oc get backupstoragelocation -n "$NS" \
        --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | grep -v "^${BSL_NAME}$" || true)
    if [ -n "$other_bsl" ]; then
        print_warn "다른 BackupStorageLocation이 감지되었습니다:"
        echo "$other_bsl" | while read -r b; do
            print_warn "  - ${b} (이 스크립트가 생성한 것이 아님, 상태 무관)"
        done
        echo ""
    fi

    print_info "연결 대상 정보 (BSL: ${BSL_NAME}):"
    print_info "  S3 Endpoint : ${S3_ENDPOINT}"
    print_info "  S3 Bucket   : ${S3_BUCKET}"
    print_info "  S3 Region   : ${S3_REGION}"
    echo ""
    print_warn "주의: BSL 검증 실패의 주요 원인"
    print_warn "  1) 버킷 미존재 — Velero는 버킷을 자동 생성하지 않습니다."
    if [ "$BACKEND" = "odf" ]; then
        print_warn "     ODF: OBC(obc-backups)로 생성된 버킷 이름을 사용합니다 → ${S3_BUCKET}"
    else
        print_warn "     MinIO: mc mb <alias>/${S3_BUCKET}  또는 콘솔에서 직접 생성"
    fi
    print_warn "  2) Endpoint 불통 — Velero Pod에서 ${S3_ENDPOINT} 에 도달 가능해야 합니다."
    print_warn "  3) 자격증명 오류 — AccessKey / SecretKey 확인"
    echo ""

    print_info "BackupStorageLocation 준비 대기 중 (BSL: ${BSL_NAME})..."
    local retries=18
    local i=0
    while [ $i -lt $retries ]; do
        local phase err_msg
        phase=$(oc get backupstoragelocation "${BSL_NAME}" -n "$NS" \
            -o jsonpath='{.status.phase}' 2>/dev/null || true)
        if [ "$phase" = "Available" ]; then
            print_ok "BackupStorageLocation ${BSL_NAME} 상태: Available"
            oc get backupstoragelocation -n "$NS" 2>/dev/null || true
            return
        fi
        err_msg=$(oc get backupstoragelocation "${BSL_NAME}" -n "$NS" \
            -o jsonpath='{.status.message}' 2>/dev/null || true)
        printf "  [%d/%d] 상태: %-12s %s\r" "$((i+1))" "$retries" "${phase:-Pending}" "${err_msg:+| $err_msg}"
        sleep 10
        i=$((i+1))
    done
    echo ""

    print_warn "BackupStorageLocation 준비 시간 초과."
    echo ""
    print_info "현재 BSL 상태:"
    oc get backupstoragelocation -n "$NS" 2>/dev/null || true
    echo ""
    print_info "상세 오류 확인 (${BSL_NAME}):"
    oc describe backupstoragelocation "${BSL_NAME}" -n "$NS" 2>/dev/null | grep -A5 "Status:\|Message:\|Phase:" || true
    echo ""
    print_info "  → oc describe backupstoragelocation ${BSL_NAME} -n ${NS}"
}

# =============================================================================
# 7단계: poc-oadp 네임스페이스 생성 (백업 대상)
# =============================================================================
VM_NS="poc-oadp"

step_vm_namespace() {
    print_step "7/9  백업 대상 네임스페이스 생성 (${VM_NS})"

    if oc get namespace "$VM_NS" &>/dev/null; then
        print_ok "네임스페이스 $VM_NS 이미 존재 — 스킵"
    else
        oc new-project "$VM_NS" > /dev/null
        print_ok "네임스페이스 $VM_NS 생성 완료"
    fi
}

# =============================================================================
# 8단계: VM 생성 (poc-oadp, poc DataSource 사용)
# =============================================================================
step_vm() {
    print_step "8/9  VM 생성 (ns: ${VM_NS})"

    if oc get vm poc-oadp-vm -n "$VM_NS" &>/dev/null; then
        print_ok "VM poc-oadp-vm 이미 존재 — 스킵"
        return
    fi

    if ! oc get template poc -n openshift &>/dev/null; then
        print_warn "poc Template 없음 — VM 생성을 건너뜁니다. (01-template 먼저 실행 필요)"
        return
    fi

    local vm_yaml="${SCRIPT_DIR}/poc-oadp-vm.yaml"
    oc process -n openshift poc -p NAME="poc-oadp-vm" | \
        sed 's/  running: false/  runStrategy: Always/' > "${vm_yaml}"
    echo "생성된 파일: ${vm_yaml}"
    confirm_and_apply "${vm_yaml}"
    print_ok "VM poc-oadp-vm 생성 완료 → ns: ${VM_NS}"
    print_info "  VM 상태 확인: oc get vm -n ${VM_NS}"
}

# =============================================================================
# 9단계: Backup CR 생성 + Restore YAML 생성 (미적용)
# =============================================================================
step_backup() {
    print_step "9/9  Backup CR 생성 (대상: ${VM_NS}, ns: ${NS})"

    # BSL 이름 동적 감지 (OADP Operator가 DPA 이름 기반으로 자동 생성, 예: poc-dpa-1)
    local bsl_name
    bsl_name=$(oc get backupstoragelocation -n "$NS" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "default")
    print_info "BackupStorageLocation: ${bsl_name}"

    if oc get backup poc-oadp-backup -n "$NS" &>/dev/null; then
        print_ok "Backup poc-oadp-backup 이미 존재 — 스킵"
    else
        cat > poc-oadp-backup.yaml <<EOF
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: poc-oadp-backup
  namespace: ${NS}
spec:
  includedNamespaces:
    - ${VM_NS}
  storageLocation: ${bsl_name}
  ttl: 720h0m0s
  snapshotVolumes: true
EOF
        confirm_and_apply poc-oadp-backup.yaml
        print_ok "Backup poc-oadp-backup 생성 완료 → ns: ${NS}"
    fi

    # Restore YAML 생성 (적용 안 함)
    cat > poc-oadp-restore.yaml <<EOF
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: poc-oadp-restore
  namespace: ${NS}
spec:
  backupName: poc-oadp-backup
  includedNamespaces:
    - ${VM_NS}
  restorePVs: true
EOF
    echo "생성된 파일: poc-oadp-restore.yaml"
    print_info "복원 시 아래 명령으로 적용하세요:"
    echo -e "    ${CYAN}oc apply -f poc-oadp-restore.yaml${NC}"
}

step_consoleyamlsamples() {
    print_step "10/10  ConsoleYAMLSample 등록"

    cat > consoleyamlsample-dpa.yaml <<EOF
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: poc-dataprotectionapplication
spec:
  title: "POC DataProtectionApplication (OADP)"
  description: "S3 호환 오브젝트 스토리지(MinIO/ODF)를 백업 스토리지로 사용하는 DataProtectionApplication 예시입니다. kubevirt, csi, openshift 플러그인을 포함합니다."
  targetResource:
    apiVersion: oadp.openshift.io/v1alpha1
    kind: DataProtectionApplication
  yaml: |
    apiVersion: oadp.openshift.io/v1alpha1
    kind: DataProtectionApplication
    metadata:
      name: poc-dpa
      namespace: ${NS}
    spec:
      configuration:
        nodeAgent:
          enable: true
          uploaderType: restic
        velero:
          defaultPlugins:
            - aws
            - openshift
            - kubevirt
            - csi
          disableFsBackup: false
      logFormat: text
      backupLocations:
        - velero:
            provider: aws
            default: true
            objectStorage:
              bucket: velero
              prefix: oadp
            config:
              profile: default
              region: us-east-1
              s3ForcePathStyle: "true"
              s3Url: http://minio.minio.svc:9000
              checksumAlgorithm: ""
            credential:
              key: cloud
              name: cloud-credentials
EOF
    oc apply -f consoleyamlsample-dpa.yaml
    print_ok "ConsoleYAMLSample poc-dataprotectionapplication 등록 완료"

    cat > consoleyamlsample-backup.yaml <<EOF
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: poc-backup
spec:
  title: "POC Backup (Velero)"
  description: "특정 네임스페이스의 VM과 볼륨을 백업하는 Velero Backup CR 예시입니다. storageLocation은 DataProtectionApplication에서 자동 생성된 BSL 이름을 사용합니다."
  targetResource:
    apiVersion: velero.io/v1
    kind: Backup
  yaml: |
    apiVersion: velero.io/v1
    kind: Backup
    metadata:
      name: poc-oadp-backup
      namespace: ${NS}
    spec:
      includedNamespaces:
        - poc-oadp
      storageLocation: poc-dpa-1
      ttl: 720h0m0s
      snapshotVolumes: true
EOF
    oc apply -f consoleyamlsample-backup.yaml
    print_ok "ConsoleYAMLSample poc-backup 등록 완료"

    cat > consoleyamlsample-restore.yaml <<EOF
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: poc-restore
spec:
  title: "POC Restore (Velero)"
  description: "Velero Backup으로부터 VM과 PV를 복원하는 Restore CR 예시입니다. 백업 완료 후 적용하세요."
  targetResource:
    apiVersion: velero.io/v1
    kind: Restore
  yaml: |
    apiVersion: velero.io/v1
    kind: Restore
    metadata:
      name: poc-oadp-restore
      namespace: ${NS}
    spec:
      backupName: poc-oadp-backup
      includedNamespaces:
        - poc-oadp
      restorePVs: true
EOF
    oc apply -f consoleyamlsample-restore.yaml
    print_ok "ConsoleYAMLSample poc-restore 등록 완료"
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
    echo -e "  VM 상태 확인 (백업 대상):"
    echo -e "    ${CYAN}oc get vm -n ${VM_NS}${NC}"
    echo ""
    echo -e "  Backup 상태 확인:"
    echo -e "    ${CYAN}oc get backup poc-oadp-backup -n ${NS}${NC}"
    echo ""
    echo -e "  복원 실행 (백업 완료 후):"
    echo -e "    ${CYAN}oc apply -f poc-oadp-restore.yaml${NC}"
    echo ""
    echo -e "  자세한 내용: 13-oadp.md 참조"
    echo ""
}

# =============================================================================
# Cleanup
# =============================================================================
cleanup() {
    print_step "--cleanup: 13-oadp 리소스 삭제"
    local _oadp_ns="${OADP_NS:-openshift-adp}"
    oc delete project poc-oadp --ignore-not-found 2>/dev/null || true
    oc delete dataprotectionapplication poc-dpa -n "$_oadp_ns" --ignore-not-found 2>/dev/null || true
    oc delete secret cloud-credentials -n "$_oadp_ns" --ignore-not-found 2>/dev/null || true
    oc delete objectbucketclaim obc-backups -n "$_oadp_ns" --ignore-not-found 2>/dev/null || true
    oc delete volumesnapshotclass poc-volumesnapshotclass --ignore-not-found 2>/dev/null || true
    oc delete consoleyamlsample poc-dataprotectionapplication poc-backup poc-restore --ignore-not-found 2>/dev/null || true
    print_ok "13-oadp 리소스 삭제 완료"
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
    step_vm_namespace
    step_vm
    step_backup
    step_consoleyamlsamples
    print_summary
}

[ "${1:-}" = "--cleanup" ] && { cleanup; exit 0; }
main
