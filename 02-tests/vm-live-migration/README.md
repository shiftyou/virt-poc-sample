# VM 라이브 마이그레이션 테스트

## 개요

실행 중인 VM을 중단 없이 다른 노드로 이동(라이브 마이그레이션)하는 기능을 테스트합니다.
VM이 실행 중인 상태에서 메모리와 디스크 상태를 유지하며 다른 노드로 이동합니다.

---

## 사전 조건

- OpenShift Virtualization 설치 완료
- 최소 2개 이상의 워커 노드
- 공유 스토리지 (ReadWriteMany 지원하는 스토리지 클래스)

---

## 적용 방법

```bash
source ../../env.conf
cd 02-tests/vm-live-migration
./apply.sh
```

---

## 테스트 절차

### 1. 테스트 VM 생성 및 시작

```bash
oc apply -f namespace.yaml
oc apply -f test-vm.yaml

# VM 시작
oc patch vm test-migration-vm -n poc-live-migration \
  --type merge -p '{"spec":{"running":true}}'

# VM 실행 확인
oc get vmi -n poc-live-migration
echo "현재 노드: $(oc get vmi test-migration-vm -n poc-live-migration \
  -o jsonpath='{.status.nodeName}')"
```

### 2. 라이브 마이그레이션 실행

```bash
# 마이그레이션 시작
oc apply -f - <<EOF
apiVersion: kubevirt.io/v1
kind: VirtualMachineInstanceMigration
metadata:
  name: test-migration-$(date +%s)
  namespace: poc-live-migration
spec:
  vmiName: test-migration-vm
EOF

# 마이그레이션 상태 확인
oc get vmim -n poc-live-migration -w
```

### 3. 마이그레이션 결과 확인

```bash
# VM 노드 변경 확인
oc get vmi test-migration-vm -n poc-live-migration \
  -o jsonpath='{.status.nodeName}'

# 마이그레이션 이력 확인
oc get vmim -n poc-live-migration
```

---

## MigrationPolicy 설정

```bash
# MigrationPolicy 확인
oc get migrationpolicy -n poc-live-migration

# 마이그레이션 제한 설정 (bandwidth, completionTimeout 등)
oc apply -f migration-policy.yaml
```

---

## 상태 확인

```bash
# VM 목록 및 노드 확인
oc get vmi -n poc-live-migration -o wide

# 마이그레이션 이력
oc get vmim -A

# 마이그레이션 진행 중 상태 확인
oc describe vmim <migration-name> -n poc-live-migration

# 마이그레이션 메트릭
oc exec -n openshift-monitoring prometheus-k8s-0 -- \
  curl -s 'http://localhost:9090/api/v1/query?query=kubevirt_vmi_migration_phase_transition_time_from_to_seconds_sum'
```

---

## 트러블슈팅

```bash
# 마이그레이션 실패 원인 확인
oc describe vmim -n poc-live-migration

# virt-handler 로그 확인
oc logs -n openshift-cnv -l kubevirt.io=virt-handler \
  --all-containers --tail=100 | grep -i "migrat"

# 스토리지가 RWX 지원하는지 확인 (라이브 마이그레이션 필수)
oc get storageclass -o custom-columns="NAME:.metadata.name,RWX:.volumeBindingMode"
oc get pvc -n poc-live-migration -o jsonpath='{.items[*].spec.accessModes}'
```
