# 18-multi-tenant: 멀티 테넌트 VM 환경

## 개요

두 개의 네임스페이스를 격리된 테넌트로 구성하고, 각 테넌트에 VM 1개를 배포한다.
사용자별 접근 권한을 RBAC으로 제어하여 멀티 테넌트 환경을 시연한다.

## 사용자 / 권한 구성

```
┌─────────────────────────────────────────────────────────────┐
│  tenant-ns1                        tenant-ns2               │
│  ┌──────────────────┐              ┌──────────────────┐     │
│  │  vm-tenant1      │              │  vm-tenant2      │     │
│  └──────────────────┘              └──────────────────┘     │
│                                                             │
│  user1  ── admin  (모든 권한)       user2  ── admin          │
│  user3  ── view   (읽기 전용)       user4  ── view           │
└─────────────────────────────────────────────────────────────┘
```

| 사용자 | 네임스페이스 | 역할  | 가능한 작업 |
|--------|------------|-------|------------|
| user1  | tenant-ns1 | admin | VM 생성/수정/삭제/콘솔 접근 |
| user2  | tenant-ns2 | admin | VM 생성/수정/삭제/콘솔 접근 |
| user3  | tenant-ns1 | view  | VM/리소스 조회만 가능 |
| user4  | tenant-ns2 | view  | VM/리소스 조회만 가능 |

- 기본 비밀번호: `Redhat1!`
- Identity Provider: HTPasswd (`poc-htpasswd`)

> user1은 tenant-ns2에 접근 불가, user2는 tenant-ns1에 접근 불가.

## 사전 준비

```bash
# htpasswd 명령 설치 (없는 경우)
dnf install -y httpd-tools

# cluster-admin 권한으로 로그인
oc login -u system:admin
```

## 실행

```bash
# 구성 실행
./18-multi-tenant.sh

# 정리
./18-multi-tenant.sh --cleanup
```

## 단계별 구성 내용

### 1. 사용자 생성 (HTPasswd)

`htpasswd` 명령으로 4명의 사용자를 생성하고,
`openshift-config` 네임스페이스의 Secret(`htpasswd-secret`)에 저장한다.

OAuth CR에 HTPasswd Identity Provider가 등록되며,
기존 IDP가 있으면 추가(append) 방식으로 등록한다.

```bash
# 수동 확인
oc get secret htpasswd-secret -n openshift-config
oc get oauth cluster -o jsonpath='{.spec.identityProviders[*].name}'
```

### 2. 네임스페이스 생성

```bash
oc get namespace tenant-ns1 tenant-ns2
```

### 3. RBAC (RoleBinding)

OpenShift 내장 ClusterRole을 사용한다:

| ClusterRole | 권한 |
|-------------|------|
| `admin`     | 네임스페이스 내 모든 리소스 생성/수정/삭제 (단, 네임스페이스 자체 삭제 불가) |
| `view`      | 네임스페이스 내 모든 리소스 조회만 가능 |

```bash
oc get rolebindings -n tenant-ns1
oc get rolebindings -n tenant-ns2
```

### 4. VM 생성

각 네임스페이스에 RHEL9 기반 VM 1개를 생성한다.

| VM 이름      | 네임스페이스 | CPU | Memory | Disk |
|-------------|------------|-----|--------|------|
| vm-tenant1  | tenant-ns1 | 1   | 2Gi    | 30Gi |
| vm-tenant2  | tenant-ns2 | 1   | 2Gi    | 30Gi |

cloud-init 기본 계정: `cloud-user / changeme`

## 검증

### CLI 권한 테스트

```bash
API=$(oc whoami --show-server)

# user1: tenant-ns1 admin — VM 삭제 가능
oc login -u user1 -p 'Redhat1!' "$API"
oc get vm -n tenant-ns1         # 성공
oc get vm -n tenant-ns2         # 실패 (접근 권한 없음)

# user3: tenant-ns1 view — 조회만 가능
oc login -u user3 -p 'Redhat1!' "$API"
oc get vm -n tenant-ns1         # 성공 (조회)
oc delete vm vm-tenant1 -n tenant-ns1  # 실패 (view 권한 부족)

# user4: tenant-ns2 view
oc login -u user4 -p 'Redhat1!' "$API"
oc get vm -n tenant-ns2         # 성공 (조회)
oc delete vm vm-tenant2 -n tenant-ns2  # 실패 (view 권한 부족)
```

### Console 접근 테스트

1. `https://<console-url>` 접속
2. Identity Provider: `poc-htpasswd` 선택
3. 각 사용자로 로그인
4. **Virtualization → VirtualMachines** 메뉴 확인
   - user1/user2: 생성 버튼 활성화
   - user3/user4: 조회만 가능, 생성/삭제 버튼 없음

### VM 콘솔 접근

```bash
# admin 사용자 (user1)는 virtctl 콘솔 접근 가능
oc login -u user1 -p 'Redhat1!' "$API"
virtctl console vm-tenant1 -n tenant-ns1
# 로그인: cloud-user / changeme
```

## 트러블슈팅

### 로그인이 안 되는 경우

HTPasswd IDP 등록 후 authentication 오퍼레이터가 재시작되는 데 1~2분이 소요된다.

```bash
# authentication 오퍼레이터 상태 확인
oc get clusteroperator authentication

# oauth-openshift Pod 재시작 확인
oc get pods -n openshift-authentication
```

### view 사용자가 VM을 볼 수 없는 경우

OpenShift Virtualization의 view 권한은 기본 `view` ClusterRole에 집계(aggregate)된다.
Virtualization 오퍼레이터가 정상 설치된 환경이면 `view` 역할로 VM 조회가 가능하다.

```bash
# view ClusterRole에 kubevirt 규칙이 포함됐는지 확인
oc get clusterrole view -o jsonpath='{.rules[*].resources}' | tr ' ' '\n' | grep -i virt
```

### DataSource 없음 오류

01-template 단계를 먼저 실행하거나 env.conf에서 DataSource를 지정한다.

```bash
# 사용 가능한 DataSource 목록
oc get datasource -n openshift-virtualization-os-images

# env.conf에 추가
DATASOURCE_NAME=fedora
DATASOURCE_NS=openshift-virtualization-os-images
```

## 정리

```bash
./18-multi-tenant.sh --cleanup
```

정리 항목:
- VM (vm-tenant1, vm-tenant2)
- 네임스페이스 (tenant-ns1, tenant-ns2) 및 내부 모든 리소스
- User 오브젝트 (user1~user4)
- Identity 오브젝트

> htpasswd secret 및 OAuth IDP 설정은 다른 사용자에게 영향을 줄 수 있으므로 수동 제거:
> ```bash
> oc delete secret htpasswd-secret -n openshift-config
> # OAuth IDP 제거: oc edit oauth cluster
> ```
