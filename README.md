# virt-poc-sample

OpenShift Virtualization POC(Proof of Concept) 샘플 모음입니다.

---

## 빠른 시작

```bash
# 1. 저장소 clone
git clone https://github.com/shiftyou/virt-poc-sample.git
cd virt-poc-sample

# 2. 환경 설정 (env.conf 생성)
./setup.sh

# 3. 전체 순서대로 실행
./make.sh
```

`make.sh` 는 `01-`, `02-` ... 번호 순서로 각 디렉토리의 `.sh` 파일을 차례로 실행합니다.
개별 단계를 수동으로 실행하려면 각 디렉토리의 `.sh` 파일을 직접 실행하세요.

---

## 전제 조건

- OpenShift 4.17 이상
- `oc` 명령어로 클러스터에 로그인된 상태 (cluster-admin 권한)
- `virtctl` 설치 — Console > `?` > **Command line tools**

---

## 사전 준비: 오퍼레이터 설치

`setup.sh` 실행 시 오퍼레이터 설치 여부를 자동으로 확인합니다.
미설치 오퍼레이터는 `00-operator/` 하위 가이드를 참조하여 설치하세요.

| 오퍼레이터 | 가이드 | 필수 여부 |
|-----------|--------|----------|
| OpenShift Virtualization | [openshift-virtualization-operator.md](00-operator/openshift-virtualization-operator.md) | 필수 |
| Migration Toolkit for Virtualization (MTV) | [mtv-operator.md](00-operator/mtv-operator.md) | VM 마이그레이션 사용 시 |
| Kubernetes NMState | [nmstate-operator.md](00-operator/nmstate-operator.md) | NNCP/NAD 사용 시 필수 |
| OADP | [oadp-operator.md](00-operator/oadp-operator.md) | 백업/복원 사용 시 |
| Fence Agents Remediation | [far-operator.md](00-operator/far-operator.md) | 노드 장애 복구 사용 시 |
| Self Node Remediation | [snr-operator.md](00-operator/snr-operator.md) | 노드 자동 복구 사용 시 |
| Kube Descheduler | [descheduler-operator.md](00-operator/descheduler-operator.md) | VM 재배치 사용 시 |
| Node Health Check | [nhc-operator.md](00-operator/nhc-operator.md) | 노드 헬스체크 사용 시 |
| Node Maintenance | [node-maintenance-operator.md](00-operator/node-maintenance-operator.md) | 노드 유지보수 사용 시 |
| Grafana | [grafana-operator.md](00-operator/grafana-operator.md) | 모니터링 대시보드 사용 시 |

---

## 환경 구성 단계

| 순서 | 디렉토리 | 설명 |
|------|----------|------|
| 01 | [01-template](01-template/01-template.md) | RHEL9 qcow2 → DataVolume → DataSource → Template 등록 |
| 02 | [02-network](02-network/02-network.md) | NNCP Linux Bridge 생성 + NAD 등록 |
| 03 | [03-vm-management](03-vm-management/03-vm-management.md) | 네임스페이스 + NAD 준비, VM 생성·스토리지·네트워크·Static IP·Live Migration |
| 04 | [04-network-policy](04-network-policy/04-network-policy.md) | NetworkPolicy 실습 — Deny All / Allow Same NS / Allow IP |

> 번호 순서가 실행 순서입니다.

---

## 디렉토리 구조

```
virt-poc-sample/
├── README.md
├── make.sh                     # 번호 순으로 전체 실행
├── setup.sh                    # 환경 변수 수집 및 env.conf 생성 (영문)
├── setup-kr.sh                 # 환경 변수 수집 및 env.conf 생성 (한글)
├── env.conf.example
│
├── 00-operator/                # 오퍼레이터 설치 가이드 (사전 준비)
│   ├── openshift-virtualization-operator.md  # 필수
│   ├── mtv-operator.md
│   ├── nmstate-operator.md
│   ├── oadp-operator.md
│   ├── far-operator.md
│   ├── snr-operator.md
│   ├── descheduler-operator.md
│   ├── nhc-operator.md
│   ├── node-maintenance-operator.md
│   └── grafana-operator.md
│
├── 01-template/                # RHEL9 황금 이미지 → Template 등록
│   ├── 01-template.md          # 가이드 문서
│   └── 01-template.sh          # 자동화 스크립트
│
├── 02-network/                 # NNCP Linux Bridge + NAD
│   ├── 02-network.md               # 가이드 문서
│   ├── 02-network.sh               # 자동화 스크립트
│   ├── consoleyamlsample-nncp.yaml # Console YAML Sample (NNCP)
│   └── consoleyamlsample-nad.yaml  # Console YAML Sample (NAD)
│
├── 03-vm-management/           # VM 생성 및 관리
│   ├── 03-vm-management.md     # 가이드 문서 (VM 생성·스토리지·네트워크·Static IP·Live Migration)
│   └── 03-vm-management.sh     # 자동화 스크립트 (네임스페이스 + NAD)
│
├── 04-network-policy/          # NetworkPolicy 실습
│   ├── 04-network-policy.md    # 가이드 문서
│   ├── 04-network-policy.sh    # 자동화 스크립트 (NS·NAD·정책·VM 배포)
│   └── netpol-allow-from-ns1-ip.yaml  # NS1→NS2 IP 허용 정책 (IP 수정 후 적용)
│
└── disabled/                   # 비활성 항목 (참고용)
```

---

## 참고 문서

- [OpenShift Virtualization 공식 문서](https://docs.redhat.com/en/documentation/openshift_container_platform/4.17/html/virtualization/index)
