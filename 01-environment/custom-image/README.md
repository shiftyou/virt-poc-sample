# 커스텀 이미지 등록 가이드

`openshift-virtualization-os-images` 네임스페이스에 직접 만든 이미지를 등록하면
Virtualization UI의 **Create VirtualMachine > From catalog** 에서 선택할 수 있습니다.

---

## 전체 흐름

```
이미지 파일 또는 URL
        │
        ▼
  DataVolume (CDI 임포트)
        │  임포트 완료
        ▼
  PVC (openshift-virtualization-os-images)
        │
        ▼
  DataSource (openshift-virtualization-os-images)
        │
        ▼
  VM 생성 시 카탈로그에서 선택 가능
```

---

## 방법 1: 로컬 파일 업로드 (virtctl)

로컬에 있는 qcow2, raw, iso 파일을 직접 클러스터로 업로드합니다.

### 사전 준비

```bash
# virtctl 설치 확인
virtctl version

# 없을 경우 다운로드 경로 확인
oc get ConsoleCLIDownload virtctl-clidownloads-kubevirt-hyperconverged \
  -o jsonpath='{.spec.links[0].href}'
```

### 업로드

```bash
# 대화형 스크립트 실행
./upload-image.sh
# → 방식 1 선택

# 또는 직접 명령어 실행
virtctl image-upload dv my-custom-os-dv \
  --image-path=/path/to/custom.qcow2 \
  --size=30Gi \
  --namespace=openshift-virtualization-os-images \
  --access-mode=ReadWriteMany \
  --volume-mode=Block \
  --storage-class=ocs-storagecluster-ceph-rbd-virtualization \
  --wait-secs=600
```

### DataSource 등록

```bash
# 업로드 완료 후 DataSource 생성
MY_IMAGE_NAME=my-custom-os MY_DV_NAME=my-custom-os-dv \
  envsubst < datasource.yaml | oc apply -f -
```

---

## 방법 2: HTTP/HTTPS URL 가져오기 (DataVolume)

인터넷 또는 내부 HTTP 서버에서 직접 이미지를 가져옵니다.

### DataVolume 생성

```bash
# 대화형 스크립트 실행
./upload-image.sh
# → 방식 2 선택

# 또는 직접 YAML 적용
MY_IMAGE_NAME=my-custom-os \
MY_IMAGE_URL=https://example.com/custom.qcow2 \
MY_IMAGE_SIZE=30Gi \
MY_STORAGE_CLASS=ocs-storagecluster-ceph-rbd-virtualization \
  envsubst < datavolume-http.yaml | oc apply -f -
```

### 임포트 진행 상황 확인

```bash
# 실시간 상태 확인
oc get dv my-custom-os-dv -n openshift-virtualization-os-images -w

# 임포트 완료까지 대기
oc wait dv my-custom-os-dv \
  --for=condition=Ready \
  --namespace=openshift-virtualization-os-images \
  --timeout=1800s
```

### DataSource 등록

```bash
# 임포트 완료 후 DataSource 생성
MY_IMAGE_NAME=my-custom-os MY_DV_NAME=my-custom-os-dv \
  envsubst < datasource.yaml | oc apply -f -
```

---

## 등록 확인

```bash
# DataSource 목록 확인
oc get datasource -n openshift-virtualization-os-images

# 등록된 커스텀 이미지만 확인
oc get datasource -n openshift-virtualization-os-images -l app=custom-os-image

# DataSource 상태 확인 (Ready 여야 함)
oc get datasource my-custom-os -n openshift-virtualization-os-images -o yaml
```

---

## VM 템플릿에서 사용

등록 후 VM YAML에서 다음과 같이 참조합니다:

```yaml
dataVolumeTemplates:
  - spec:
      sourceRef:
        kind: DataSource
        name: my-custom-os                           # 등록한 이름
        namespace: openshift-virtualization-os-images
      storage:
        resources:
          requests:
            storage: 30Gi
```

---

## 등록된 이미지 삭제

```bash
# DataSource 삭제 (PVC는 유지)
oc delete datasource my-custom-os -n openshift-virtualization-os-images

# PVC까지 함께 삭제
oc delete pvc my-custom-os-dv -n openshift-virtualization-os-images
```

---

## 트러블슈팅

```bash
# DataVolume 이벤트 확인
oc describe dv my-custom-os-dv -n openshift-virtualization-os-images

# CDI 임포터 Pod 로그 확인
oc logs -n openshift-virtualization-os-images \
  $(oc get pod -n openshift-virtualization-os-images \
    -l cdi.kubevirt.io/storage.import.importPvcName=my-custom-os-dv \
    -o name)

# 스토리지 클래스별 접근 모드 확인
oc get storageprofile -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.claimPropertySets}{"\n"}{end}'
```
