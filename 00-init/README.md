# 00-init: 사전 준비

OpenShift Virtualization POC 시작 전, 필요한 Operator 설치 여부를 확인하고 POC용 VM 이미지를 준비합니다.

> `setup.sh` 를 먼저 실행하면 현재 클러스터의 오퍼레이터 설치 상태를 자동으로 확인합니다.

---

## 1. 오퍼레이터 설치 확인

POC 항목에 따라 필요한 오퍼레이터가 다릅니다. 아래 오퍼레이터가 설치되어 있어야 각 기능을 테스트할 수 있습니다.

| 오퍼레이터 | 필요 기능 | 설치 가이드 |
|------------|----------|-------------|
| OpenShift Virtualization | VM 생성/관리 (필수) | [01-openshift-virtualization.md](01-openshift-virtualization.md) |
| OADP Operator | VM 백업/복원 | [02-oadp-operator.md](02-oadp-operator.md) |
| Fence Agents Remediation | 노드 장애 복구 (IPMI) | [03-far-operator.md](03-far-operator.md) |
| Self Node Remediation | 자동 노드 복구 | [04-snr-operator.md](04-snr-operator.md) |
| Kube Descheduler | 워크로드 재배치 | [05-descheduler-operator.md](05-descheduler-operator.md) |
| Node Health Check | 노드 상태 감지 | [06-nhc-operator.md](06-nhc-operator.md) |

### 설치 상태 일괄 확인

```bash
# CSV(ClusterServiceVersion) 목록으로 설치된 오퍼레이터 확인
oc get csv -A | grep -E "kubevirt|oadp|fence|remediation|descheduler|healthcheck|maintenance"

# 구독 상태 확인
oc get subscription -A
```

---

## 2. POC용 커스텀 VM 이미지 준비

POC 테스트에서 사용할 VM 이미지(rhel9-poc-golden)를 준비합니다.

| 가이드 | 설명 |
|--------|------|
| [custom-vm-image.md](custom-vm-image.md) | RHEL9 VM 생성 → 구독 등록 → httpd 설치 → qcow2 추출 |
| [pvc-to-qcow2.md](pvc-to-qcow2.md) | qcow2 ↔ openshift-virtualization-os-images 변환 및 업로드 |

### 커스텀 이미지 관련 파일

| 파일 | 설명 |
|------|------|
| [`upload-image.sh`](upload-image.sh) | 커스텀 이미지 업로드 대화형 스크립트 |
| [`datavolume-http.yaml`](datavolume-http.yaml) | HTTP URL DataVolume 임포트 템플릿 |
| [`datasource.yaml`](datasource.yaml) | DataSource 등록 템플릿 |
| [`custom-image-consoleyamlsample.yaml`](custom-image-consoleyamlsample.yaml) | Console Import YAML 샘플 |

---

## 3. OpenShift Virtualization 설치 확인

```bash
# HyperConverged CR 상태 확인
oc get hyperconverged -n openshift-cnv

# virt-operator Pod 확인
oc get pods -n openshift-cnv | grep virt-operator

# CDI(ContainerDataImporter) 상태 확인
oc get cdi -A
```
