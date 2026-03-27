# 노드 유지보수 (Kubelet 중지/재시작)

## 개요

노드 유지보수 작업 시 노드를 안전하게 클러스터에서 제외하고 다시 복귀시키는 방법을 설명합니다.

- **Cordon**: 노드에 신규 Pod 스케줄링 차단
- **Drain**: 노드의 Pod를 다른 노드로 이동 후 Cordon
- **Kubelet 중지/재시작**: 노드 에이전트 제어

---

## 파일 설명

| 파일 | 설명 |
|------|------|
| [`node-maintenance.sh`](node-maintenance.sh) | 노드 drain/cordon/uncordon 자동화 스크립트 |

---

## 노드 유지보수 절차

### 1. 노드 Cordon (스케줄링 차단)

```bash
# 특정 노드에 신규 Pod 스케줄링 차단
oc adm cordon ${TEST_NODE}

# 노드 상태 확인 (SchedulingDisabled 표시)
oc get node ${TEST_NODE}
```

### 2. 노드 Drain (Pod 이동)

```bash
# 노드의 모든 Pod를 다른 노드로 이동
# --ignore-daemonsets: DaemonSet Pod는 제외
# --delete-emptydir-data: emptyDir 볼륨 Pod도 이동
oc adm drain ${TEST_NODE} \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --force \
  --timeout=300s

# VM이 있는 경우 VM이 다른 노드로 라이브 마이그레이션됨
oc get vmi -A -o custom-columns="NAME:.metadata.name,NODE:.status.nodeName"
```

### 3. Kubelet 중지

```bash
# 노드에 접속하여 kubelet 중지
oc debug node/${TEST_NODE} -- chroot /host systemctl stop kubelet

# 또는 node-maintenance.sh 스크립트 사용
./node-maintenance.sh stop ${TEST_NODE}
```

### 4. Kubelet 재시작

```bash
# kubelet 재시작
oc debug node/${TEST_NODE} -- chroot /host systemctl start kubelet

# kubelet 상태 확인
oc debug node/${TEST_NODE} -- chroot /host systemctl status kubelet
```

### 5. 노드 Uncordon (스케줄링 재개)

```bash
# 유지보수 완료 후 노드 다시 활성화
oc adm uncordon ${TEST_NODE}

# 노드 상태 확인 (Ready 상태)
oc get node ${TEST_NODE}
```

---

## 스크립트 사용

```bash
source ../../env.conf
cd 01-environment/node-maintenance

# 노드 유지보수 시작 (drain + stop)
./node-maintenance.sh start ${TEST_NODE}

# 노드 유지보수 종료 (start + uncordon)
./node-maintenance.sh finish ${TEST_NODE}
```

---

## 상태 확인

```bash
# 노드 상태 확인
oc get node ${TEST_NODE}

# 노드 상세 정보 (Taint, Condition 확인)
oc describe node ${TEST_NODE}

# 노드의 Pod 목록
oc get pod -A --field-selector spec.nodeName=${TEST_NODE}

# 노드 CPU/Memory 사용량
oc adm top node ${TEST_NODE}

# Kubelet 상태 확인
oc debug node/${TEST_NODE} -- chroot /host systemctl status kubelet
```

---

## VM 라이브 마이그레이션 확인

노드 drain 시 VM은 다른 노드로 라이브 마이그레이션됩니다:

```bash
# 마이그레이션 진행 상황 확인
oc get virtualmachineinstancemigration -A

# 마이그레이션 완료 후 VM 위치 확인
oc get vmi -A -o wide
```

---

## 트러블슈팅

```bash
# Drain 실패 시 Pod 확인
oc get pod -A --field-selector spec.nodeName=${TEST_NODE} | grep -v Completed

# PodDisruptionBudget 확인 (drain 차단 원인)
oc get pdb -A

# 강제 삭제 (주의)
oc adm drain ${TEST_NODE} \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --force \
  --grace-period=0
```
