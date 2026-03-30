#!/bin/bash
# =============================================================================
# 18-multi-tenant.sh
#
# 멀티 테넌트 VM 환경 구성
#   - 네임스페이스 2개 생성 (tenant-ns1, tenant-ns2)
#   - user1: tenant-ns1 admin
#   - user2: tenant-ns2 admin
#   - user3: tenant-ns1 view (read-only)
#   - user4: tenant-ns2 view (read-only)
#   - 각 네임스페이스에 VM 1개 생성
#
# 사용법: ./18-multi-tenant.sh [--cleanup]
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

# =============================================================================
# 설정
# =============================================================================
NS1="tenant-ns1"
NS2="tenant-ns2"

USER1="user1"   # NS1 admin
USER2="user2"   # NS2 admin
USER3="user3"   # NS1 view (read-only)
USER4="user4"   # NS2 view (read-only)

DEFAULT_PASS="Redhat1!"

HTPASSWD_SECRET="htpasswd-secret"
HTPASSWD_IDP_NAME="poc-htpasswd"
HTPASSWD_TMP="/tmp/poc-htpasswd-$$"

DATASOURCE_NS="${DATASOURCE_NS:-openshift-virtualization-os-images}"
DATASOURCE_NAME="${DATASOURCE_NAME:-rhel9}"
STORAGE_CLASS="${STORAGE_CLASS:-ocs-external-storagecluster-ceph-rbd}"

# =============================================================================
preflight() {
    print_step "사전 확인"

    if ! oc whoami &>/dev/null; then
        print_error "OpenShift에 로그인되어 있지 않습니다."
        exit 1
    fi
    print_ok "클러스터 접속: $(oc whoami) @ $(oc whoami --show-server)"

    if ! command -v htpasswd &>/dev/null; then
        print_error "htpasswd 명령이 없습니다."
        print_info "설치: dnf install -y httpd-tools"
        exit 1
    fi
    print_ok "htpasswd 명령 확인"
}

# =============================================================================
step_users() {
    print_step "사용자 생성 (HTPasswd Identity Provider)"

    # 기존 htpasswd secret 내용 가져오기
    if oc get secret "$HTPASSWD_SECRET" -n openshift-config &>/dev/null; then
        print_info "기존 htpasswd secret 발견 → 사용자 추가"
        oc get secret "$HTPASSWD_SECRET" \
            -n openshift-config \
            -o jsonpath='{.data.htpasswd}' | base64 -d > "$HTPASSWD_TMP"
    else
        print_info "새 htpasswd 파일 생성"
        touch "$HTPASSWD_TMP"
    fi

    # 4명 사용자 생성/업데이트
    for user in "$USER1" "$USER2" "$USER3" "$USER4"; do
        htpasswd -bB "$HTPASSWD_TMP" "$user" "$DEFAULT_PASS" 2>/dev/null
        print_ok "사용자: ${CYAN}${user}${NC}  (비밀번호: ${DEFAULT_PASS})"
    done

    # htpasswd secret 생성 or 업데이트
    if oc get secret "$HTPASSWD_SECRET" -n openshift-config &>/dev/null; then
        oc set data secret "$HTPASSWD_SECRET" \
            --from-file=htpasswd="$HTPASSWD_TMP" \
            -n openshift-config
        print_ok "htpasswd secret 업데이트 완료"
    else
        oc create secret generic "$HTPASSWD_SECRET" \
            --from-file=htpasswd="$HTPASSWD_TMP" \
            -n openshift-config
        print_ok "htpasswd secret 생성 완료"
    fi
    rm -f "$HTPASSWD_TMP"

    # OAuth CR에 HTPasswd IDP 등록 (없으면 추가)
    if oc get oauth cluster \
        -o jsonpath='{.spec.identityProviders[*].name}' 2>/dev/null | \
        tr ' ' '\n' | grep -qx "$HTPASSWD_IDP_NAME"; then
        print_ok "OAuth IDP '${HTPASSWD_IDP_NAME}' 이미 등록됨"
    else
        local idp_json
        idp_json="{\"name\":\"${HTPASSWD_IDP_NAME}\",\"mappingMethod\":\"claim\",\"type\":\"HTPasswd\",\"htpasswd\":{\"fileData\":{\"name\":\"${HTPASSWD_SECRET}\"}}}"

        # 기존 배열에 추가 시도, 실패하면 배열 신규 생성
        if ! oc patch oauth cluster --type=json \
            -p="[{\"op\":\"add\",\"path\":\"/spec/identityProviders/-\",\"value\":${idp_json}}]" \
            2>/dev/null; then
            oc patch oauth cluster --type=merge \
                -p="{\"spec\":{\"identityProviders\":[${idp_json}]}}"
        fi
        print_ok "OAuth IDP '${HTPASSWD_IDP_NAME}' 등록 완료"
        print_warn "authentication 오퍼레이터 재시작까지 1~2분 소요됩니다."
    fi
}

# =============================================================================
step_namespaces() {
    print_step "네임스페이스 생성"

    for ns in "$NS1" "$NS2"; do
        if oc get namespace "$ns" &>/dev/null; then
            print_warn "네임스페이스 이미 존재: $ns"
        else
            oc create namespace "$ns"
            print_ok "네임스페이스 생성: ${CYAN}${ns}${NC}"
        fi
    done
}

# =============================================================================
step_rbac() {
    print_step "RBAC 설정"

    echo ""
    printf "  %-10s  %-20s  %s\n" "사용자" "네임스페이스" "역할"
    echo "  ──────────────────────────────────────────────"

    oc adm policy add-role-to-user admin "$USER1" -n "$NS1" 2>/dev/null
    printf "  %-10s  %-20s  %s\n" "$USER1" "$NS1" "admin  (모든 권한)"
    print_ok "${USER1} → ${NS1} [admin]"

    oc adm policy add-role-to-user admin "$USER2" -n "$NS2" 2>/dev/null
    printf "  %-10s  %-20s  %s\n" "$USER2" "$NS2" "admin  (모든 권한)"
    print_ok "${USER2} → ${NS2} [admin]"

    oc adm policy add-role-to-user view "$USER3" -n "$NS1" 2>/dev/null
    printf "  %-10s  %-20s  %s\n" "$USER3" "$NS1" "view   (읽기 전용)"
    print_ok "${USER3} → ${NS1} [view]"

    oc adm policy add-role-to-user view "$USER4" -n "$NS2" 2>/dev/null
    printf "  %-10s  %-20s  %s\n" "$USER4" "$NS2" "view   (읽기 전용)"
    print_ok "${USER4} → ${NS2} [view]"
}

# =============================================================================
create_vm() {
    local ns="$1"
    local vm_name="$2"

    if oc get vm "$vm_name" -n "$ns" &>/dev/null; then
        print_warn "VM 이미 존재: ${vm_name} (${ns})"
        return 0
    fi

    oc apply -f - <<EOF
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${vm_name}
  namespace: ${ns}
  labels:
    app: ${vm_name}
spec:
  runStrategy: Always
  template:
    metadata:
      labels:
        kubevirt.io/domain: ${vm_name}
    spec:
      domain:
        cpu:
          cores: 1
          sockets: 1
          threads: 1
        devices:
          disks:
          - name: rootdisk
            disk:
              bus: virtio
          - name: cloudinitdisk
            disk:
              bus: virtio
        resources:
          requests:
            memory: 2Gi
      volumes:
      - name: rootdisk
        dataVolume:
          name: ${vm_name}-rootdisk
      - name: cloudinitdisk
        cloudInitNoCloud:
          userData: |
            #cloud-config
            user: cloud-user
            password: changeme
            chpasswd: { expire: False }
  dataVolumeTemplates:
  - metadata:
      name: ${vm_name}-rootdisk
    spec:
      sourceRef:
        kind: DataSource
        name: ${DATASOURCE_NAME}
        namespace: ${DATASOURCE_NS}
      storage:
        accessModes:
        - ReadWriteMany
        resources:
          requests:
            storage: 30Gi
        storageClassName: ${STORAGE_CLASS}
EOF
    print_ok "VM 생성: ${CYAN}${vm_name}${NC} (namespace: ${ns})"
}

step_vms() {
    print_step "VM 생성 (네임스페이스당 1개)"

    # DataSource 존재 확인
    if ! oc get datasource "$DATASOURCE_NAME" -n "$DATASOURCE_NS" &>/dev/null; then
        print_warn "DataSource '${DATASOURCE_NAME}' (${DATASOURCE_NS}) 없음"
        print_info "01-template 단계를 먼저 실행하거나 DATASOURCE_NAME 변수를 변경하세요."
        print_info "VM 생성을 건너뜁니다."
        return 0
    fi

    create_vm "$NS1" "vm-tenant1"
    create_vm "$NS2" "vm-tenant2"

    # 기동 대기
    echo ""
    print_info "VM 기동 대기 중 (최대 5분)..."
    local retries=30
    local i=0
    while [ "$i" -lt "$retries" ]; do
        local s1 s2
        s1=$(oc get vmi vm-tenant1 -n "$NS1" \
            -o jsonpath='{.status.phase}' 2>/dev/null || echo "-")
        s2=$(oc get vmi vm-tenant2 -n "$NS2" \
            -o jsonpath='{.status.phase}' 2>/dev/null || echo "-")

        if [ "$s1" = "Running" ] && [ "$s2" = "Running" ]; then
            echo ""
            print_ok "vm-tenant1 (${NS1}) → Running"
            print_ok "vm-tenant2 (${NS2}) → Running"
            break
        fi
        printf "  대기 중... tenant1=%s  tenant2=%s  (%d/%d)\r" \
            "$s1" "$s2" "$((i+1))" "$retries"
        sleep 10
        i=$((i+1))
    done
    echo ""
}

# =============================================================================
step_verify() {
    print_step "검증"

    echo ""
    print_info "━━ 네임스페이스 ━━"
    oc get namespace "$NS1" "$NS2" --no-headers \
        -o custom-columns='NAME:.metadata.name,STATUS:.status.phase'

    echo ""
    print_info "━━ RoleBinding ━━"
    for ns in "$NS1" "$NS2"; do
        echo "  [${ns}]"
        oc get rolebindings -n "$ns" --no-headers \
            -o custom-columns='BINDING:.metadata.name,ROLE:.roleRef.name,SUBJECT:.subjects[0].name' \
            2>/dev/null | grep -E "user[1-4]" | \
            awk '{printf "    %-35s %-10s %s\n", $1, $2, $3}' || true
    done

    echo ""
    print_info "━━ VM ━━"
    oc get vm -n "$NS1" -n "$NS2" \
        -o custom-columns='NAME:.metadata.name,NS:.metadata.namespace,STATUS:.status.printableStatus' \
        2>/dev/null || \
    { oc get vm -n "$NS1" 2>/dev/null; oc get vm -n "$NS2" 2>/dev/null; } || true
}

# =============================================================================
cleanup() {
    print_step "정리 (cleanup)"

    print_info "VM 삭제..."
    oc delete vm vm-tenant1 -n "$NS1" --ignore-not-found
    oc delete vm vm-tenant2 -n "$NS2" --ignore-not-found

    print_info "네임스페이스 삭제 (RoleBinding 포함)..."
    oc delete namespace "$NS1" --ignore-not-found
    oc delete namespace "$NS2" --ignore-not-found

    print_info "User / Identity 삭제..."
    for user in "$USER1" "$USER2" "$USER3" "$USER4"; do
        oc delete user "$user" --ignore-not-found 2>/dev/null || true
        oc delete identity "${HTPASSWD_IDP_NAME}:${user}" --ignore-not-found 2>/dev/null || true
    done

    print_ok "정리 완료"
    print_warn "htpasswd secret 및 OAuth IDP 설정은 수동으로 제거하세요."
    print_cmd "oc delete secret ${HTPASSWD_SECRET} -n openshift-config"
}

# =============================================================================
print_summary() {
    local api_url console_url
    api_url=$(oc whoami --show-server 2>/dev/null || echo "")
    console_url=$(oc get route console -n openshift-console \
        -o jsonpath='{.spec.host}' 2>/dev/null || echo "<console-url>")

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  완료! Multi-Tenant 환경 구성이 끝났습니다.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${CYAN}━━ 사용자 / 권한 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    printf "  %-8s  %-20s  %-18s  %s\n" "사용자" "네임스페이스" "역할" "비밀번호"
    echo "  ─────────────────────────────────────────────────────────────"
    printf "  %-8s  %-20s  %-18s  %s\n" "$USER1" "$NS1" "admin (모든 권한)"    "$DEFAULT_PASS"
    printf "  %-8s  %-20s  %-18s  %s\n" "$USER2" "$NS2" "admin (모든 권한)"    "$DEFAULT_PASS"
    printf "  %-8s  %-20s  %-18s  %s\n" "$USER3" "$NS1" "view  (읽기 전용)"   "$DEFAULT_PASS"
    printf "  %-8s  %-20s  %-18s  %s\n" "$USER4" "$NS2" "view  (읽기 전용)"   "$DEFAULT_PASS"
    echo ""
    echo -e "  ${CYAN}━━ Console 로그인 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  URL: ${BLUE}https://${console_url}${NC}"
    echo -e "  IDP: ${CYAN}${HTPASSWD_IDP_NAME}${NC}"
    echo ""
    echo -e "  ${CYAN}━━ CLI 전환 테스트 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${CYAN}oc login -u user1 -p '${DEFAULT_PASS}' ${api_url}${NC}"
    echo -e "  ${CYAN}oc get vm -n ${NS1}${NC}   # 조회 가능"
    echo -e "  ${CYAN}oc login -u user3 -p '${DEFAULT_PASS}' ${api_url}${NC}"
    echo -e "  ${CYAN}oc delete vm vm-tenant1 -n ${NS1}${NC}  # 거부됨 (view only)"
    echo ""
    echo -e "  자세한 내용: 18-multi-tenant.md 참조"
    echo ""
}

# =============================================================================
main() {
    if [ "${1:-}" = "--cleanup" ]; then
        echo ""
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${YELLOW}  18-multi-tenant: 정리 모드${NC}"
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        preflight
        cleanup
        return 0
    fi

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  18-multi-tenant: 멀티 테넌트 VM 환경 구성${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    preflight
    step_users
    step_namespaces
    step_rbac
    step_vms
    step_verify
    print_summary
}

main "$@"
