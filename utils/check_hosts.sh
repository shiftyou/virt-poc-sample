#!/bin/bash

# 모니터링할 호스트 목록 (공백으로 구분)
HOSTS=("google.com" "naver.com" "github.com" "example.com")

# 색상 코드
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# 화면 초기화 및 헤더 출력 함수
display_status() {
    clear
    echo "======================================================"
    echo "  Host Status Monitor (Port 80) - $(date '+%Y-%m-%d %H:%M:%S')"
    echo "======================================================"
    printf "%-20s | %-10s | %-10s\n" "HOST" "STATUS" "HTTP CODE"
    echo "------------------------------------------------------"

    for host in "${HOSTS[@]}"; do
        # curl 옵션 설명:
        # -s: 정적 모드, -o /dev/null: 바디 출력 안함, -w: 출력 포맷 지정, --connect-timeout: 타임아웃 2초
        http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 "http://$host")

        if [ "$http_code" -eq 200 ] || [ "$http_code" -eq 301 ] || [ "$http_code" -eq 302 ]; then
            status_text="${GREEN}ONLINE${NC}"
        else
            status_text="${RED}OFFLINE${NC}"
        fi

        printf "%-20s | %-20b | %-10s\n" "$host" "$status_text" "$http_code"
    done
    echo "======================================================"
    echo "Press [CTRL+C] to stop."
}

# 무한 루프 (2초 간격 업데이트)
while true; do
    display_status
    sleep 2
done
