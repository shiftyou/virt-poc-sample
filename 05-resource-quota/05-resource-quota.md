# ResourceQuota 실습

`poc-resource-quota` 네임스페이스에 ResourceQuota를 적용하여
VM 2개는 통과, 3번째 VM은 CPU quota 초과로 거부되는 것을 확인하는 실습입니다.

```
초기 상태 (Quota 내)
┌────────────────────────────────────────────────┐
│  poc-resource-quota                            │
│                                                │
│  ● poc-quota-vm-1  (cpu request: 750m) ✅      │
│  ● poc-quota-vm-2  (cpu request: 750m) ✅      │
│                                                │
│  requests.cpu 사용: 1500m / 2000m              │
└────────────────────────────────────────────────┘

3번째 VM 생성 시도 → Quota 초과
┌────────────────────────────────────────────────┐
│  poc-resource-quota                            │
│                                                │
│  ● poc-quota-vm-1  (750m) ✅                   │
│  ● poc-quota-vm-2  (750m) ✅                   │
│  ✗ poc-quota-vm-3  (750m) → 2250m > 2000m     │
│                             virt-launcher 거부  │
└────────────────────────────────────────────────┘
```

---

## 사전 조건

- cluster-admin 또는 네임스페이스 admin 권한
- `01-template` 완료 — poc Template 등록
- `05-resource-quota.sh` 실행 완료

---

## 적용된 ResourceQuota

| 항목 | requests | limits |
|------|----------|--------|
| CPU | **2 core** | 4 core |
| Memory | 4 Gi | 8 Gi |
| Pod 수 | — | 10 |
| PVC 수 | — | 10 |
| Storage | 100 Gi | — |
| Service | — | 10 |
| LoadBalancer | — | 2 |
| NodePort | — | 0 |
| ConfigMap | — | 20 |
| Secret | — | 20 |

> `requests.cpu: "2"` (2000m) 기준 — VM 각 750m → 2개(1500m) 통과, 3개(2250m) 초과

---

## 실습 확인

### 초기 상태 확인

```bash
# ResourceQuota 현황
oc describe resourcequota poc-quota -n poc-resource-quota

# 예시 출력
# Resource                  Used    Hard
# --------                  ----    ----
# limits.cpu                3000m   4
# limits.memory             4Gi     8Gi
# requests.cpu              1500m   2       ← 2개 VM 후 1500m 사용 중
# requests.memory           2Gi     4Gi
# pods                      2       10
```

### VM 상태 확인

```bash
# VM 목록
oc get vm -n poc-resource-quota

# NAME             AGE   STATUS    READY
# poc-quota-vm-1   ...   Running   True
# poc-quota-vm-2   ...   Running   True
# poc-quota-vm-3   ...   Stopped   False   ← virt-launcher Pod 기동 불가

# virt-launcher Pod 상태
oc get pod -n poc-resource-quota -l kubevirt.io=virt-launcher
```

### Quota 초과 이벤트 확인

```bash
# Quota 초과 이벤트
oc get events -n poc-resource-quota --field-selector reason=FailedCreate \
  --sort-by='.lastTimestamp'

# 예시 출력
# ...  FailedCreate  ...  pods "virt-launcher-poc-quota-vm-3-..."
#      is forbidden: exceeded quota: poc-quota,
#      requested: requests.cpu=750m, used: requests.cpu=1500m,
#      limited: requests.cpu=2
```

### virt-launcher Pod 리소스 확인

```bash
# 실행 중인 VM의 실제 CPU/Memory 사용량
oc get pod -n poc-resource-quota -l kubevirt.io=virt-launcher \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{range .spec.containers[*]}  {.name}: cpu={.resources.requests.cpu} mem={.resources.requests.memory}{"\n"}{end}{end}'
```

---

## ResourceQuota 초과 테스트 (추가)

```bash
# Quota 여유 확인
oc describe resourcequota poc-quota -n poc-resource-quota

# Quota 한도 올려서 vm-3 기동 가능하게
oc patch resourcequota poc-quota -n poc-resource-quota \
  --type=merge \
  -p '{"spec":{"hard":{"requests.cpu":"4","limits.cpu":"8"}}}'

# vm-3 재시작
virtctl start poc-quota-vm-3 -n poc-resource-quota

# Quota 다시 내려서 초과 상태 복원
oc patch resourcequota poc-quota -n poc-resource-quota \
  --type=merge \
  -p '{"spec":{"hard":{"requests.cpu":"2","limits.cpu":"4"}}}'
```

---

## LimitRange 함께 사용 (권장)

ResourceQuota와 함께 LimitRange를 설정하면 requests/limits 미지정 Pod에
기본값을 자동으로 적용합니다.

```bash
oc apply -f - <<'EOF'
apiVersion: v1
kind: LimitRange
metadata:
  name: poc-limitrange
  namespace: poc-resource-quota
spec:
  limits:
    - type: Container
      default:
        cpu: 500m
        memory: 512Mi
      defaultRequest:
        cpu: 250m
        memory: 256Mi
      max:
        cpu: "2"
        memory: 4Gi
      min:
        cpu: 50m
        memory: 64Mi
    - type: PersistentVolumeClaim
      max:
        storage: 50Gi
      min:
        storage: 1Gi
EOF

# LimitRange 확인
oc get limitrange -n poc-resource-quota
oc describe limitrange poc-limitrange -n poc-resource-quota
```

---

## 롤백

```bash
# 네임스페이스 삭제 (VM, Quota, LimitRange 포함)
oc delete namespace poc-resource-quota
```
