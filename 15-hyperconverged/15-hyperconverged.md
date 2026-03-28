# HyperConverged 설정 실습

HyperConverged CR을 통해 OpenShift Virtualization 클러스터 전체 설정을 변경합니다.

---

## HyperConverged CR 개요

```bash
# HyperConverged CR 확인
oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv -o yaml
```

---

## 1. CPU Overcommit (vCPU:pCPU 비율) 변경

기본값은 `10:1`입니다. 워크로드 특성에 따라 조정합니다.

```
CPU Overcommit = vCPU 수 / pCPU 수
기본값: 10 (vCPU 10개 당 pCPU 1개)
```

### 현재 설정 확인

```bash
oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv \
  -o jsonpath='{.spec.resourceRequirements.vmiCPUAllocationRatio}{"\n"}'
```

### Overcommit 비율 변경

```bash
# 예: 4:1 (pCPU 1개당 vCPU 4개 허용)
oc patch hyperconverged kubevirt-hyperconverged \
  -n openshift-cnv \
  --type=merge \
  -p '{"spec":{"resourceRequirements":{"vmiCPUAllocationRatio":4}}}'
```

| 비율 | 설명 | 적합한 환경 |
|------|------|------------|
| `1` | No overcommit (1:1) | CPU 집약적 워크로드 |
| `4` | 4:1 | 균형 잡힌 환경 |
| `10` | 10:1 (기본값) | 일반 POC / 혼합 워크로드 |

> **주의**: Overcommit이 높을수록 CPU 경쟁 시 VM 성능 저하 발생 가능

---

## 2. Memory Overcommit

메모리 Overcommit은 `spec.higherWorkloadDensity`로 설정합니다.

```bash
# Memory Overcommit 활성화 (Swap 활용)
oc patch hyperconverged kubevirt-hyperconverged \
  -n openshift-cnv \
  --type=merge \
  -p '{"spec":{"higherWorkloadDensity":{"memoryOvercommitPercentage":150}}}'
```

| 값 | 의미 |
|----|------|
| `100` | No overcommit (기본) |
| `150` | 물리 메모리의 1.5배 VM 메모리 허용 |

---

## 3. Live Migration 설정

```bash
# Live Migration 동시 실행 수 및 대역폭 설정
oc patch hyperconverged kubevirt-hyperconverged \
  -n openshift-cnv \
  --type=merge \
  -p '{
    "spec": {
      "liveMigrationConfig": {
        "parallelMigrationsPerCluster": 5,
        "parallelOutboundMigrationsPerNode": 2,
        "bandwidthPerMigration": "64Mi",
        "completionTimeoutPerGiB": 800,
        "progressTimeout": 150
      }
    }
  }'
```

| 항목 | 기본값 | 설명 |
|------|--------|------|
| `parallelMigrationsPerCluster` | 5 | 클러스터 전체 동시 Migration 수 |
| `parallelOutboundMigrationsPerNode` | 2 | 노드당 동시 송신 Migration 수 |
| `bandwidthPerMigration` | 0 (무제한) | Migration당 네트워크 대역폭 제한 |
| `completionTimeoutPerGiB` | 800 | GiB당 완료 타임아웃 (초) |
| `progressTimeout` | 150 | 진행 없을 때 타임아웃 (초) |

---

## 4. Feature Gates (기능 플래그)

```bash
# 현재 Feature Gates 확인
oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv \
  -o jsonpath='{.spec.featureGates}'

# GPU Passthrough 활성화
oc patch hyperconverged kubevirt-hyperconverged \
  -n openshift-cnv \
  --type=merge \
  -p '{"spec":{"featureGates":{"deployKubeSecondaryDNS":true}}}'
```

---

## 5. Mediating Device (GPU / SR-IOV)

```bash
# Mediated Device (예: GPU vGPU) 설정
oc patch hyperconverged kubevirt-hyperconverged \
  -n openshift-cnv \
  --type=merge \
  -p '{
    "spec": {
      "mediatedDevicesConfiguration": {
        "mediatedDevicesTypes": ["nvidia-231"]
      },
      "permittedHostDevices": {
        "mediatedDevices": [
          {
            "mdevNameSelector": "GRID T4-4Q",
            "resourceName": "nvidia.com/GRID_T4-4Q"
          }
        ]
      }
    }
  }'
```

---

## 6. StorageClass 기본값 설정

```bash
source env.conf

# Virtualization 전용 기본 StorageClass 지정
oc patch hyperconverged kubevirt-hyperconverged \
  -n openshift-cnv \
  --type=merge \
  -p "{
    \"spec\": {
      \"storageImport\": {
        \"insecureRegistries\": []
      }
    }
  }"

# DataImportCron 기본 StorageClass 설정
oc patch hco kubevirt-hyperconverged \
  -n openshift-cnv \
  --type=merge \
  -p "{\"spec\":{\"dataImportCronTemplates\":[]}}"
```

---

## 변경 확인 및 적용

```bash
# HyperConverged 상태 확인
oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv

# 변경사항 실시간 확인
oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv \
  -o jsonpath='{.spec.resourceRequirements}{"\n"}'

# KubeVirt CR에 반영 확인 (HyperConverged → KubeVirt 자동 반영)
oc get kubevirt kubevirt -n openshift-cnv \
  -o jsonpath='{.spec.configuration.developerConfiguration}{"\n"}'
```

---

## 롤백

```bash
# CPU Overcommit 기본값으로 복원
oc patch hyperconverged kubevirt-hyperconverged \
  -n openshift-cnv \
  --type=merge \
  -p '{"spec":{"resourceRequirements":{"vmiCPUAllocationRatio":10}}}'

# Live Migration 설정 초기화
oc patch hyperconverged kubevirt-hyperconverged \
  -n openshift-cnv \
  --type=json \
  -p '[{"op":"remove","path":"/spec/liveMigrationConfig"}]' 2>/dev/null || true
```
