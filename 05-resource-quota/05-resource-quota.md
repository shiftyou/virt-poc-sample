# ResourceQuota 실습

`poc-resource-quota` 네임스페이스에 ResourceQuota를 적용하여
CPU·Memory·Pod 등의 리소스 사용량을 제한하는 실습입니다.

---

## 사전 조건

- cluster-admin 또는 네임스페이스 admin 권한
- `05-resource-quota.sh` 실행 완료

---

## 적용된 ResourceQuota

| 항목 | requests | limits |
|------|----------|--------|
| CPU | 4 core | 8 core |
| Memory | 8 Gi | 16 Gi |
| Pod 수 | — | 10 |
| PVC 수 | — | 10 |
| Storage | 100 Gi | — |
| Service | — | 10 |
| LoadBalancer | — | 2 |
| NodePort | — | 0 |
| ConfigMap | — | 20 |
| Secret | — | 20 |

---

## 현황 확인

```bash
# ResourceQuota 사용량 확인
oc get resourcequota -n poc-resource-quota

# 상세 현황 (Used / Hard)
oc describe resourcequota poc-quota -n poc-resource-quota

# 예시 출력
# Resource                  Used  Hard
# --------                  ----  ----
# configmaps                1     20
# limits.cpu                0     8
# limits.memory             0     16Gi
# persistentvolumeclaims    0     10
# pods                      0     10
# requests.cpu              0     4
# requests.memory           0     8Gi
# requests.storage          0     100Gi
# secrets                   5     20
# services                  0     10
# services.loadbalancers    0     2
# services.nodeports        0     0
```

---

## ResourceQuota 초과 테스트

ResourceQuota를 초과하면 리소스 생성이 거부됩니다.

```bash
# Pod 10개 초과 시 거부 확인
oc run test-pod --image=nginx -n poc-resource-quota
# Error: pods "test-pod" is forbidden: exceeded quota: poc-quota,
#        requested: pods=1, used: pods=10, limited: pods=10

# CPU requests 없는 Pod 생성 시도 (Quota가 있으면 requests 필수)
# Error: must specify limits.cpu, requests.cpu
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
        cpu: "4"
        memory: 8Gi
      min:
        cpu: 50m
        memory: 64Mi
    - type: Pod
      max:
        cpu: "8"
        memory: 16Gi
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

## VM에 ResourceQuota 적용 시 주의사항

OpenShift Virtualization VM은 `virt-launcher` Pod로 실행됩니다.
VM 생성 시 requests/limits가 자동 계산되므로 Quota 여유를 충분히 확보하세요.

```bash
# VM의 실제 리소스 사용량 확인
oc get pod -n poc-resource-quota -l kubevirt.io=virt-launcher \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{range .spec.containers[*]}  {.name}: cpu={.resources.requests.cpu} mem={.resources.requests.memory}{"\n"}{end}{end}'

# Quota 남은 용량 확인 후 VM 생성 가능 여부 판단
oc describe resourcequota poc-quota -n poc-resource-quota
```

---

## Quota 수정

```bash
# 특정 항목 변경
oc patch resourcequota poc-quota -n poc-resource-quota \
  --type=merge \
  -p '{"spec":{"hard":{"pods":"20","limits.cpu":"16"}}}'

# 또는 전체 재적용
oc apply -f resourcequota-poc.yaml
```

---

## 롤백

```bash
# ResourceQuota 삭제
oc delete resourcequota poc-quota -n poc-resource-quota

# LimitRange 삭제 (생성한 경우)
oc delete limitrange poc-limitrange -n poc-resource-quota

# 네임스페이스 삭제
oc delete namespace poc-resource-quota
```
