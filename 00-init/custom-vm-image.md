# POC용 커스텀 VM 이미지 생성 가이드

OpenShift Virtualization POC 테스트에 사용할 RHEL9 기반 커스텀 VM 이미지를 준비합니다.
RHEL9 VM을 생성하여 구독을 등록하고 httpd를 설치한 뒤, PVC를 qcow2로 추출하여
`openshift-virtualization-os-images` 네임스페이스에 황금 이미지로 등록합니다.

```
RHEL9 기본 이미지 (OCP 제공)
        │  VM 생성 (rhel9-vm)
        ▼
subscription-manager 등록 + httpd 설치
        │  VM 종료
        ▼
PVC → qcow2 (virtctl vmexport)
        │  virtctl image-upload
        ▼
PVC: rhel9-poc-golden  (openshift-virtualization-os-images)
        │  DataSource 등록
        ▼
DataSource: rhel9-poc-golden  → 클러스터 전체에서 VM 생성 가능
```

---

## 1단계: RHEL9 VM 생성

OpenShift Virtualization UI 또는 CLI로 RHEL9 VM을 생성합니다.

### CLI로 생성

```bash
# poc-vm-build 네임스페이스 생성
oc new-project poc-vm-build

# RHEL9 기본 템플릿으로 VM 생성 (기존 RHEL9 템플릿 사용)
oc process -n openshift rhel9-server-small \
  -p NAME=rhel9-vm \
  -p NAMESPACE=poc-vm-build | oc apply -f -
```

### VM 시작 및 접속

```bash
# VM 시작
virtctl start rhel9-vm -n poc-vm-build

# VM이 Running 상태가 될 때까지 대기
oc wait vm/rhel9-vm -n poc-vm-build \
  --for=jsonpath='{.status.printableStatus}'=Running --timeout=300s

# VNC 콘솔 접속
virtctl vnc rhel9-vm -n poc-vm-build

# 또는 SSH (cloud-init으로 SSH 키 주입한 경우)
virtctl ssh cloud-user@rhel9-vm -n poc-vm-build
```

---

## 2단계: RHEL 구독 등록

VM 콘솔 또는 SSH로 접속 후 Red Hat 구독을 등록합니다.

```bash
# 구독 등록 (Red Hat 계정 사용)
subscription-manager register \
  --username <사용자이름> \
  --password <패스워드> \
  --auto-attach

# 등록 확인
subscription-manager status
subscription-manager list --installed
```

---

## 3단계: httpd 설치 및 POC 웹 서버 구성

아래 스크립트를 VM 내에서 실행합니다.

```bash
#!/bin/bash

# 1. 필수 패키지 설치 (httpd, firewalld, tar, wget)
echo ">>> [1/5] 기본 패키지 설치 중..."
dnf install -y httpd firewalld tar wget bash-completion

# 2. BMT 웹 서버 설정 (index.html)
echo ">>> [4/5] BMT 안내 페이지 생성 중..."
cat <<EOF > /var/www/html/index.html
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <title>OpenShift BMT</title>
    <style>
        body { font-family: 'Segoe UI', sans-serif; text-align: center; margin-top: 80px; background-color: #f0f2f5; }
        .card { background: white; border-top: 8px solid #ee0000; display: inline-block; padding: 40px; border-radius: 12px; box-shadow: 0 10px 30px rgba(0,0,0,0.1); }
        h1 { color: #ee0000; margin-bottom: 5px; font-size: 2.2em; }
        h2 { color: #333; font-weight: 400; margin-top: 15px; border-top: 1px solid #eee; padding-top: 15px; }
        .info { margin-top: 20px; font-size: 0.9em; color: #666; }
    </style>
</head>
<body>
    <div class="card">
        <h1>OpenShift Virtualization PoC/BMT Test</h1>
        <h2>Node Hostname: $(hostname)</h2>
        <div class="info">CLI Tools Installed: oc, kubectl, virtctl</div>
    </div>
</body>
</html>
EOF

# 3. 서비스 활성화 및 방화벽 개방
echo ">>> [5/5] 서비스 활성화 및 방화벽 설정..."
systemctl enable --now httpd firewalld
firewall-cmd --permanent --add-service=http
firewall-cmd --reload

echo "------------------------------------------------"
echo "✅ 모든 설정이 완료되었습니다!"
echo "1. Web 접속: http://$(hostname -I | awk '{print $1}')"
echo "2. oc 버전: $(oc version --client)"
echo "3. virtctl 버전: $(virtctl version --client | grep Client)"
echo "------------------------------------------------"
```

설치 확인:

```bash
# httpd 서비스 상태
systemctl status httpd

# 웹 서버 응답 확인
curl http://localhost
```

---

## 4단계: VM 종료

이미지 추출 전 VM을 완전히 종료합니다.

```bash
# VM 안에서 종료
sudo shutdown -h now
```

또는 외부에서:

```bash
virtctl stop rhel9-vm -n poc-vm-build

# 완전히 종료될 때까지 대기
oc wait vm/rhel9-vm -n poc-vm-build \
  --for=jsonpath='{.status.printableStatus}'=Stopped --timeout=120s
```

---

## 5단계: PVC를 qcow2로 추출

VM의 루트 디스크 PVC를 로컬 qcow2 파일로 내보냅니다.

```bash
# PVC 이름 확인
oc get pvc -n poc-vm-build

# VMExport 생성
virtctl vmexport create rhel9-poc-export \
  --pvc=<rhel9-vm의 rootdisk PVC 이름> \
  -n poc-vm-build

# Ready 상태 확인
oc get vmexport rhel9-poc-export -n poc-vm-build

# qcow2 다운로드
virtctl vmexport download rhel9-poc-export \
  --output=./rhel9-poc-export.qcow2 \
  -n poc-vm-build

# VMExport 정리
virtctl vmexport delete rhel9-poc-export -n poc-vm-build
```

> **상세 가이드**: [pvc-to-qcow2.md](pvc-to-qcow2.md) Part 1 참조

---

## 6단계: 황금 이미지로 등록

추출한 qcow2를 `openshift-virtualization-os-images` 네임스페이스에 업로드하고 DataSource로 등록합니다.

```bash
# qcow2 업로드
virtctl image-upload dv rhel9-poc-golden \
  --image-path=rhel9-poc-golden.qcow2 \
  --size=30Gi \
  --storage-class=ocs-external-storagecluster-ceph-rbd \
  --access-mode=ReadWriteMany \
  --volume-mode=block \
  -n openshift-virtualization-os-images \
  --insecure \
  --force-bind

# DataSource 등록
cat <<'EOF' | oc apply -f -
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataSource
metadata:
  name: rhel9-poc-golden
  namespace: openshift-virtualization-os-images
spec:
  source:
    pvc:
      name: rhel9-poc-golden
      namespace: openshift-virtualization-os-images
EOF

# 등록 확인
oc get datasource rhel9-poc-golden -n openshift-virtualization-os-images
```

> **상세 가이드**: [pvc-to-qcow2.md](pvc-to-qcow2.md) Part 2 참조

---

## 참고

- `virtctl` 설치: OpenShift Console > `?` 메뉴 > **Command line tools** 에서 다운로드
- 대화형 업로드 스크립트: [`upload-image.sh`](upload-image.sh)
- StorageClass 확인: `oc get storageclass`
