# Resource Limits (LimitRange + ResourceQuota)

## 개요

네임스페이스에서 Pod/Container의 CPU, Memory 사용량을 제한하고,
네임스페이스 전체의 리소스 총량을 제한합니다.

- **LimitRange**: 개별 Pod/Container의 CPU/Memory 기본값 및 최대값 설정
- **ResourceQuota**: 네임스페이스 전체의 총 리소스 사용량 제한

---

## 적용 방법

```bash
source ../../env.conf

cd 01-environment/resource-limits
./apply.sh
```

---

## 파일 설명

| 파일 | 설명 |
|------|------|
| [`namespace.yaml`](namespace.yaml) | poc-resource-limits 네임스페이스 |
| [`limitrange.yaml`](limitrange.yaml) | Container/Pod/PVC 개별 리소스 제한 |
| [`resourcequota.yaml`](resourcequota.yaml) | 네임스페이스 전체 리소스 총량 제한 |
| [`apply.sh`](apply.sh) | 적용 스크립트 |

---

## 상태 확인

```bash
# LimitRange 확인
oc get limitrange -n poc-resource-limits
oc describe limitrange poc-limitrange -n poc-resource-limits

# ResourceQuota 확인
oc get resourcequota -n poc-resource-limits
oc describe resourcequota poc-quota -n poc-resource-limits

# 네임스페이스 리소스 사용량 확인
oc adm top pod -n poc-resource-limits
oc adm top node

# CPU/Memory 사용 현황 요약
oc describe namespace poc-resource-limits
```

---

## 테스트 방법

```bash
# 리소스 제한 초과 Pod 생성 테스트 (실패해야 함)
oc run test-exceed --image=nginx \
  --requests='cpu=10,memory=100Gi' \
  -n poc-resource-limits

# 정상 범위 Pod 생성 테스트 (성공해야 함)
oc run test-normal --image=nginx \
  --requests='cpu=100m,memory=128Mi' \
  -n poc-resource-limits

# ResourceQuota 초과 테스트
# 여러 Pod를 생성하여 quota 초과 확인
for i in $(seq 1 10); do
  oc run test-pod-${i} --image=nginx -n poc-resource-limits
done

# 결과 확인
oc get pods -n poc-resource-limits
oc describe resourcequota poc-quota -n poc-resource-limits
```

---

## 트러블슈팅

```bash
# Pod 생성 실패 이유 확인
oc get events -n poc-resource-limits --sort-by='.lastTimestamp' | grep -i "forbidden\|exceeded"

# LimitRange 적용 확인
oc get pod <pod-name> -n poc-resource-limits -o jsonpath='{.spec.containers[*].resources}'
```
