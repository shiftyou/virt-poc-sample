# MinIO 구성 (OADP S3 Backend)

## 개요

MinIO는 S3 호환 오브젝트 스토리지로, airgap 환경에서 OADP의 백업 저장소로 사용합니다.
OpenShift 내부에 MinIO를 배포하여 VM 백업/복원에 활용합니다.

---

## 사전 조건

- `setup.sh`에서 MinIO 정보 입력 (MINIO_ACCESS_KEY, MINIO_SECRET_KEY, MINIO_BUCKET)
- 스토리지 클래스 사용 가능한 상태

---

## 적용 방법

```bash
# 프로젝트 루트에서
source env.conf

cd 01-environment/minio

# MinIO 배포
envsubst < minio-deploy.yaml | oc apply -f -
envsubst < minio-service.yaml | oc apply -f -
envsubst < minio-route.yaml | oc apply -f -

# 또는 apply.sh 사용
./apply.sh
```

---

## 파일 설명

| 파일 | 설명 |
|------|------|
| [`minio-deploy.yaml`](minio-deploy.yaml) | MinIO Deployment + PVC |
| [`minio-service.yaml`](minio-service.yaml) | MinIO Service (9000, 9001 포트) |
| [`minio-route.yaml`](minio-route.yaml) | MinIO 외부 접근 Route |
| [`apply.sh`](apply.sh) | 전체 배포 스크립트 |

---

## 버킷 생성

MinIO 배포 후 OADP용 버킷을 생성합니다:

```bash
# MinIO Route 확인
MINIO_ROUTE=$(oc get route minio-console -n poc-minio -o jsonpath='{.spec.host}')
echo "MinIO Console: http://${MINIO_ROUTE}"

# mc (MinIO Client)로 버킷 생성
mc alias set local http://${MINIO_ROUTE} ${MINIO_ACCESS_KEY} ${MINIO_SECRET_KEY}
mc mb local/${MINIO_BUCKET}
mc ls local/

# 또는 MinIO API로 버킷 생성
MINIO_API_ROUTE=$(oc get route minio -n poc-minio -o jsonpath='{.spec.host}')
curl -X PUT http://${MINIO_API_ROUTE}/${MINIO_BUCKET} \
  --aws-sigv4 "aws:amz:us-east-1:s3" \
  -u "${MINIO_ACCESS_KEY}:${MINIO_SECRET_KEY}"
```

---

## 상태 확인

```bash
# MinIO Pod 상태 확인
oc get pods -n poc-minio

# MinIO Service 확인
oc get svc -n poc-minio

# MinIO Route 확인
oc get route -n poc-minio

# MinIO PVC 확인
oc get pvc -n poc-minio

# MinIO 로그 확인
oc logs -n poc-minio deployment/minio
```

---

## CPU / Memory 상태 확인

```bash
# MinIO Pod 리소스 사용량
oc adm top pod -n poc-minio

# MinIO PVC 사용량
oc get pvc -n poc-minio
```

---

## 트러블슈팅

```bash
# MinIO Pod 이벤트 확인
oc describe pod -n poc-minio -l app=minio

# MinIO 로그 확인 (오류 메시지)
oc logs -n poc-minio deployment/minio --tail=50

# S3 연결 테스트
curl -v http://${MINIO_ENDPOINT}/${MINIO_BUCKET}
```
