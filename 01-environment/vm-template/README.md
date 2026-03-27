# VM Template 생성

## 개요

OpenShift Virtualization에서 VM 생성 시 사용하는 Template을 생성합니다.

**중요:** Template을 모든 네임스페이스에서 사용하려면 **`openshift` 네임스페이스**에 생성해야 합니다.
특정 네임스페이스에 생성하면 해당 네임스페이스에서만 사용 가능합니다.

---

## 파일 설명

| 파일 | 설명 |
|------|------|
| [`vm-template.yaml`](vm-template.yaml) | RHEL9 기본 이미지(`rhel9` DataSource) 기반 VM Template |
| [`poc-template.yaml`](poc-template.yaml) | `poc` DataSource(커스텀 골든 이미지) 기반 POC 전용 Template |

---

## Template 위치

| 위치 | 접근 범위 |
|------|---------|
| `openshift` 네임스페이스 | 모든 네임스페이스에서 접근 가능 |
| 특정 네임스페이스 | 해당 네임스페이스에서만 접근 가능 |

---

## Red Hat 제공 기본 Template

OpenShift Virtualization 설치 시 기본 Template이 `openshift` 네임스페이스에 자동 생성됩니다.

```bash
# 기본 제공 Template 목록 확인
oc get template -n openshift | grep -E "rhel|fedora|windows|centos"

# Template 상세 확인
oc describe template rhel9-server-small -n openshift

# Template의 파라미터 확인
oc process --parameters -n openshift rhel9-server-small
```

---

## 적용 방법

```bash
# 프로젝트 루트에서
source env.conf

# openshift 네임스페이스에 커스텀 Template 생성
oc apply -f vm-template.yaml -n openshift

# 특정 네임스페이스에 Template 생성
oc apply -f vm-template.yaml -n poc-vm-template
```

---

## Template에서 VM 생성

```bash
# Template 목록 확인
oc get template -n openshift

# Template으로 VM 생성 (파라미터 지정)
oc process -n openshift rhel9-server-small \
  -p NAME=my-rhel9-vm \
  -p NAMESPACE=poc-test | oc apply -f -

# 커스텀 Template으로 VM 생성 (기본 rhel9 이미지)
oc process -n openshift poc-rhel9-vm-template \
  -p NAME=test-vm \
  -p NAMESPACE=poc-test \
  -p CPU_CORES=2 \
  -p MEMORY=4Gi | oc apply -f -
```

---

## poc-template 사용법

`poc` DataSource(커스텀 골든 이미지)를 부팅 소스로 사용하는 POC 전용 템플릿입니다.

### 사전 조건

`00-init/custom-vm-image.md` 6단계 절차에 따라 `poc` DataSource가 등록되어 있어야 합니다.

```bash
# DataSource 등록 여부 확인
oc get datasource poc -n openshift-virtualization-os-images
```

### 템플릿 등록

```bash
oc apply -f poc-template.yaml
```

### VM 생성

```bash
# 기본 파라미터로 VM 생성 (NAME 자동 생성)
oc process -n openshift poc | oc apply -n poc-test -f -

# NAME 지정
oc process -n openshift poc -p NAME=my-poc-vm | oc apply -n poc-test -f -
```

---

## 상태 확인

```bash
# Template 목록 확인
oc get template -n openshift | grep poc

# Template 상세 내용 확인
oc get template poc-vm-template -n openshift -o yaml

# Template으로 생성된 VM 확인
oc get vm -A

# VM 상태 확인
oc get vmi -A
```

---

## 트러블슈팅

```bash
# Template 파라미터 오류 확인
oc process -n openshift poc-vm-template --dry-run=client

# VM 생성 이벤트 확인
oc get events -n <namespace> --sort-by='.lastTimestamp'

# VM Pod 확인
oc get pods -n <namespace> | grep virt-launcher
```
