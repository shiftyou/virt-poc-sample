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

- OpenShift 4.17 이상 + OpenShift Virtualization Operator 설치
- `oc` 명령어로 클러스터에 로그인된 상태 (cluster-admin 권한)
- `virtctl` 설치 — Console > `?` > **Command line tools**

---

## 단계별 가이드

| 순서 | 디렉토리 | 설명 |
|------|----------|------|
| 01 | [01-make-template](01-make-template/01-make-template.md) | RHEL9 qcow2 → DataVolume → DataSource → Template 등록 |

> 번호 순서가 실행 순서입니다.

---

## 디렉토리 구조

```
virt-poc-sample/
├── README.md
├── make.sh                     # 번호 순으로 전체 실행
├── setup.sh                    # 환경 변수 수집 및 env.conf 생성
├── setup-kr.sh                 # 환경 변수 수집 및 env.conf 생성 (한글)
├── env.conf.example
│
├── 01-make-template/           # RHEL9 황금 이미지 → Template 등록
│   ├── 01-make-template.md     # 가이드 문서
│   └── 01-make-template.sh     # 자동화 스크립트
│
└── disabled/                   # 비활성 항목 (참고용)
```

---

## 참고 문서

- [OpenShift Virtualization 공식 문서](https://docs.redhat.com/en/documentation/openshift_container_platform/4.17/html/virtualization/index)
