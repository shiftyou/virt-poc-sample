# VM 스냅샷/복원 테스트

## 개요

VirtualMachineSnapshot을 사용하여 VM의 특정 시점 상태를 저장하고,
VirtualMachineRestore로 해당 시점으로 복원하는 기능을 테스트합니다.

---

## 사전 조건

- OpenShift Virtualization 설치 완료
- VolumeSnapshotClass 지원하는 스토리지

---

## 적용 방법

```bash
source ../../env.conf
cd 02-tests/vm-snapshot
./apply.sh
```

---

## 테스트 절차

### 1. VM 생성 및 시작

```bash
oc apply -f namespace.yaml
oc apply -f test-vm.yaml
oc patch vm test-snapshot-vm -n poc-vm-snapshot \
  --type merge -p '{"spec":{"running":true}}'

# VM 접속하여 테스트 파일 생성
oc exec -n poc-vm-snapshot \
  $(oc get pod -n poc-vm-snapshot -l kubevirt.io/domain=test-snapshot-vm -o name) \
  -- sh -c 'echo "Before snapshot" > /tmp/test.txt'
```

### 2. 스냅샷 생성

```bash
# 스냅샷 생성 (VM 중지 없이 가능)
oc apply -f vm-snapshot.yaml

# 스냅샷 상태 확인 (ReadyToUse가 true여야 함)
oc get vmsnapshot -n poc-vm-snapshot -w
```

### 3. VM 상태 변경

```bash
# 스냅샷 후 VM 파일 수정
oc exec -n poc-vm-snapshot \
  $(oc get pod -n poc-vm-snapshot -l kubevirt.io/domain=test-snapshot-vm -o name) \
  -- sh -c 'echo "After snapshot" > /tmp/test.txt'
```

### 4. 스냅샷으로 복원

```bash
# VM 중지
oc patch vm test-snapshot-vm -n poc-vm-snapshot \
  --type merge -p '{"spec":{"running":false}}'

# 스냅샷으로 복원
oc apply -f vm-restore.yaml

# 복원 상태 확인
oc get vmrestore -n poc-vm-snapshot -w

# VM 재시작 후 파일 확인 (스냅샷 이전 상태여야 함)
oc patch vm test-snapshot-vm -n poc-vm-snapshot \
  --type merge -p '{"spec":{"running":true}}'
```

---

## 상태 확인

```bash
# 스냅샷 목록
oc get vmsnapshot -n poc-vm-snapshot

# 스냅샷 상세 정보
oc describe vmsnapshot test-vm-snapshot -n poc-vm-snapshot

# 복원 목록
oc get vmrestore -n poc-vm-snapshot

# VolumeSnapshot 확인 (스냅샷의 실제 데이터)
oc get volumesnapshot -n poc-vm-snapshot
```

---

## 트러블슈팅

```bash
# 스냅샷 생성 실패 시 확인
oc describe vmsnapshot test-vm-snapshot -n poc-vm-snapshot

# VolumeSnapshotClass 확인
oc get volumesnapshotclass

# CDI 상태 확인
oc get cdi -n openshift-cnv
```
