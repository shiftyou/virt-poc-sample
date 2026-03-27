#!/bin/bash
# =============================================================================
# 01-template.sh
#
# rhel9-poc-golden.qcow2 → DataVolume → DataSource → Template 등록
# 실행하면 openshift 네임스페이스에 poc Template이 생성됩니다.
#
# 사용법: ./01-template.sh [qcow2-파일-경로]
#   예) ./01-template.sh
#   예) ./01-template.sh /path/to/rhel9-poc-golden.qcow2
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../env.conf"

TARGET_NS="openshift-virtualization-os-images"
DV_NAME="poc-golden"
DS_NAME="poc"
TEMPLATE_NAME="poc"
TEMPLATE_NS="openshift"
DISK_SIZE="30Gi"

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
# 사전 확인
# =============================================================================
preflight() {
    print_step "사전 확인"

    # env.conf
    if [ ! -f "$ENV_FILE" ]; then
        print_error "env.conf 를 찾을 수 없습니다. setup.sh 를 먼저 실행하세요."
        exit 1
    fi
    source "$ENV_FILE"
    print_ok "env.conf 로드 (STORAGE_CLASS=${STORAGE_CLASS})"

    # oc 로그인
    if ! oc whoami &>/dev/null; then
        print_error "OpenShift 에 로그인되어 있지 않습니다."
        exit 1
    fi
    print_ok "클러스터 접속: $(oc whoami) @ $(oc whoami --show-server)"

    # virtctl
    if ! command -v virtctl &>/dev/null; then
        print_error "virtctl 을 찾을 수 없습니다."
        echo "  설치: oc get ConsoleCLIDownload virtctl-clidownloads-kubevirt-hyperconverged \\"
        echo "          -o jsonpath='{.spec.links[0].href}'"
        exit 1
    fi
    print_ok "virtctl: $(virtctl version --client 2>/dev/null | sed -n 's/.*GitVersion:"v\([^"]*\)".*/\1/p' | head -1 || echo 'found')"

    # qcow2 파일
    if [ -n "${1:-}" ]; then
        IMAGE_PATH="$1"
    else
        IMAGE_PATH="${SCRIPT_DIR}/../rhel9-poc-golden.qcow2"
    fi

    if [ ! -f "$IMAGE_PATH" ]; then
        print_error "이미지 파일을 찾을 수 없습니다: $IMAGE_PATH"
        echo "  사용법: $0 [qcow2-파일-경로]"
        exit 1
    fi
    print_ok "이미지 파일: $IMAGE_PATH ($(du -sh "$IMAGE_PATH" | cut -f1))"
}

# =============================================================================
# 1단계: DataVolume 업로드
# =============================================================================
step_upload() {
    print_step "1/3  DataVolume 업로드 (poc-golden)"

    # 이미 존재하고 Succeeded 상태면 스킵
    local phase
    phase=$(oc get dv "$DV_NAME" -n "$TARGET_NS" \
        -o jsonpath='{.status.phase}' 2>/dev/null || true)

    if [ "$phase" = "Succeeded" ]; then
        print_ok "DataVolume $DV_NAME 이미 존재합니다 (Succeeded) — 업로드 스킵"
        return
    elif [ -n "$phase" ]; then
        print_warn "DataVolume $DV_NAME 상태: $phase — 재업로드합니다"
        oc delete dv "$DV_NAME" -n "$TARGET_NS" --ignore-not-found
        oc delete pvc "$DV_NAME" -n "$TARGET_NS" --ignore-not-found
    fi

    print_info "업로드 시작 (시간이 걸릴 수 있습니다)..."
    virtctl image-upload dv "$DV_NAME" \
        --image-path="$IMAGE_PATH" \
        --size="$DISK_SIZE" \
        --storage-class="${STORAGE_CLASS}" \
        --access-mode=ReadWriteMany \
        --volume-mode=block \
        -n "$TARGET_NS" \
        --insecure \
        --force-bind

    print_ok "DataVolume 업로드 완료"
}

# =============================================================================
# 2단계: DataSource 등록
# =============================================================================
step_datasource() {
    print_step "2/3  DataSource 등록 (poc)"

    oc apply -f - <<EOF
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataSource
metadata:
  name: ${DS_NAME}
  namespace: ${TARGET_NS}
spec:
  source:
    pvc:
      name: ${DV_NAME}
      namespace: ${TARGET_NS}
EOF

    # Ready 확인
    local ready
    ready=$(oc get datasource "$DS_NAME" -n "$TARGET_NS" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    if [ "$ready" = "True" ]; then
        print_ok "DataSource $DS_NAME Ready"
    else
        print_ok "DataSource $DS_NAME 생성 완료 (상태: ${ready:-Unknown})"
    fi
}

# =============================================================================
# 3단계: Template 등록
# =============================================================================
step_template() {
    print_step "3/3  Template 등록 (poc @ openshift)"

    oc apply -f - <<'EOF'
apiVersion: template.openshift.io/v1
kind: Template
metadata:
  name: poc
  namespace: openshift
  labels:
    app.kubernetes.io/part-of: hyperconverged-cluster
    flavor.template.kubevirt.io/small: 'true'
    template.kubevirt.io/version: v0.31.1
    template.kubevirt.io/type: vm
    vm.kubevirt.io/template: rhel9-server-small
    app.kubernetes.io/component: templating
    app.kubernetes.io/managed-by: ssp-operator
    os.template.kubevirt.io/rhel9.0: 'true'
    os.template.kubevirt.io/rhel9.1: 'true'
    os.template.kubevirt.io/rhel9.2: 'true'
    os.template.kubevirt.io/rhel9.3: 'true'
    os.template.kubevirt.io/rhel9.4: 'true'
    os.template.kubevirt.io/rhel9.5: 'true'
    vm.kubevirt.io/template.namespace: openshift
    app.kubernetes.io/name: custom-templates
    workload.template.kubevirt.io/server: 'true'
  annotations:
    openshift.io/display-name: POC VM
    description: Template for Red Hat Enterprise Linux 9 VM or newer.
    tags: 'hidden,kubevirt,virtualmachine,linux,rhel'
    iconClass: icon-rhel
    template.kubevirt.io/version: v1alpha1
    defaults.template.kubevirt.io/disk: rootdisk
    template.openshift.io/bindable: 'false'
    openshift.kubevirt.io/pronounceable-suffix-for-name-expression: 'true'
    name.os.template.kubevirt.io/rhel9.0: Red Hat Enterprise Linux 9.0 or higher
    name.os.template.kubevirt.io/rhel9.1: Red Hat Enterprise Linux 9.0 or higher
    name.os.template.kubevirt.io/rhel9.2: Red Hat Enterprise Linux 9.0 or higher
    name.os.template.kubevirt.io/rhel9.3: Red Hat Enterprise Linux 9.0 or higher
    name.os.template.kubevirt.io/rhel9.4: Red Hat Enterprise Linux 9.0 or higher
    name.os.template.kubevirt.io/rhel9.5: Red Hat Enterprise Linux 9.0 or higher
objects:
  - apiVersion: kubevirt.io/v1
    kind: VirtualMachine
    metadata:
      annotations:
        vm.kubevirt.io/validations: |
          [
            {
              "name": "minimal-required-memory",
              "path": "jsonpath::.spec.domain.memory.guest",
              "rule": "integer",
              "message": "This VM requires more memory.",
              "min": 1610612736
            }
          ]
      labels:
        app: '${NAME}'
        kubevirt.io/dynamic-credentials-support: 'true'
        vm.kubevirt.io/template: poc
        vm.kubevirt.io/template.revision: '1'
        vm.kubevirt.io/template.namespace: openshift
      name: '${NAME}'
    spec:
      dataVolumeTemplates:
        - apiVersion: cdi.kubevirt.io/v1beta1
          kind: DataVolume
          metadata:
            name: '${NAME}'
          spec:
            sourceRef:
              kind: DataSource
              name: '${DATA_SOURCE_NAME}'
              namespace: '${DATA_SOURCE_NAMESPACE}'
            storage:
              resources:
                requests:
                  storage: 30Gi
      running: false
      template:
        metadata:
          annotations:
            vm.kubevirt.io/flavor: small
            vm.kubevirt.io/os: rhel9
            vm.kubevirt.io/workload: server
          labels:
            kubevirt.io/domain: '${NAME}'
            kubevirt.io/size: small
        spec:
          architecture: amd64
          domain:
            cpu:
              cores: 1
              sockets: 1
              threads: 1
            devices:
              disks:
                - disk:
                    bus: virtio
                  name: rootdisk
                - disk:
                    bus: virtio
                  name: cloudinitdisk
              interfaces:
                - masquerade: {}
                  model: virtio
                  name: default
              rng: {}
            features:
              smm:
                enabled: true
            firmware:
              bootloader:
                efi: {}
            memory:
              guest: 2Gi
          networks:
            - name: default
              pod: {}
          terminationGracePeriodSeconds: 180
          volumes:
            - dataVolume:
                name: '${NAME}'
              name: rootdisk
            - cloudInitNoCloud:
                userData: |-
                  #cloud-config
                  user: cloud-user
                  password: ${CLOUD_USER_PASSWORD}
                  chpasswd: { expire: False }
              name: cloudinitdisk
parameters:
  - name: NAME
    description: VM name
    generate: expression
    from: 'poc-[a-z0-9]{16}'
  - name: DATA_SOURCE_NAME
    description: Name of the DataSource to clone
    value: poc
  - name: DATA_SOURCE_NAMESPACE
    description: Namespace of the DataSource
    value: openshift-virtualization-os-images
  - name: CLOUD_USER_PASSWORD
    description: Randomized password for the cloud-init user cloud-user
    generate: expression
    from: '[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}'
EOF

    print_ok "Template $TEMPLATE_NAME 등록 완료 (namespace: $TEMPLATE_NS)"
}

# =============================================================================
# 완료 요약
# =============================================================================
print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  완료! POC VM Template 이 등록되었습니다.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  DataVolume : ${CYAN}oc get dv ${DV_NAME} -n ${TARGET_NS}${NC}"
    echo -e "  DataSource : ${CYAN}oc get datasource ${DS_NAME} -n ${TARGET_NS}${NC}"
    echo -e "  Template   : ${CYAN}oc get template ${TEMPLATE_NAME} -n ${TEMPLATE_NS}${NC}"
    echo ""
    echo -e "  VM 생성:"
    echo -e "  ${CYAN}oc process -n openshift poc | oc apply -n <네임스페이스> -f -${NC}"
    echo ""
    echo -e "  또는 Console > Virtualization > Catalog > 'POC VM' 선택"
    echo ""
}

# =============================================================================
# 메인
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  POC Golden Image → Template 등록${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    preflight "${1:-}"
    step_upload
    step_datasource
    step_template
    print_summary
}

main "${1:-}"
