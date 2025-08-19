#!/usr/bin/env bash
set -euo pipefail

# ===== 설정값 =====
THRESHOLD=55.0                             # 임계치(%)
COOLDOWN_SECONDS=600                       # 알림 쿨다운(초)
LOG_DIR="/var/log/sysmetrics"              # 수집 로그 위치 (logger.sh 출력)
SES_REGION="ap-northeast-2"                # SES 리전 (예: 서울)
FROM="insulin90@gmail.com"                  # SES에서 인증된 발신자
TO="insulin90@gmail.com"                       # 수신자 (SES 샌드박스면 인증 필요)
HOSTNAME="$(hostname -f 2>/dev/null || hostname)"
LOCK_FILE="/tmp/mem_watch.lock"
LAST_FILE="/tmp/mem_watch.last"
TMPDIR="${TMPDIR:-/tmp}"
export PATH=/usr/local/bin:/usr/bin:/bin
umask 022
# ===================

mkdir -p "$LOG_DIR"

# 중복 실행 방지 (최대 50초 대기)
exec 9>"$LOCK_FILE"
if ! flock -w 50 9; then
  echo "[mem_watch] another instance is running (timeout)"
  exit 0
fi

# 쿨다운 체크
NOW=$(date +%s)
if [[ -f "$LAST_FILE" ]]; then
  LAST=$(cat "$LAST_FILE" || echo 0)
  if (( NOW - LAST < COOLDOWN_SECONDS )); then
    echo "[mem_watch] cooldown active: $((NOW - LAST))s elapsed"
    exit 0
  fi
fi

# 메모리 사용률 계산 (MemTotal/MemAvailable)
MT=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
MA=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
if [[ "$MT" -gt 0 ]]; then
  USAGE=$(awk -v t="$MT" -v a="$MA" 'BEGIN{printf "%.1f", (t-a)/t*100}')
else
  echo "[mem_watch] cannot read /proc/meminfo"
  exit 1
fi

echo "[mem_watch] usage=${USAGE}% threshold=${THRESHOLD}%"

# 임계 미만이면 종료
awk -v u="$USAGE" -v th="$THRESHOLD" 'BEGIN{exit (u>=th)?0:1}' || exit 0

# 최신 로그 파일 찾기
ATTACH_PATH=""
if compgen -G "$LOG_DIR/*.log" > /dev/null; then
  ATTACH_PATH=$(ls -1t "$LOG_DIR"/*.log | head -n1 || true)
fi

if [[ -z "$ATTACH_PATH" || ! -s "$ATTACH_PATH" ]]; then
  # 없으면 임시 파일로 대체
  ATTACH_PATH="$TMPDIR/mem_watch_no_log.txt"
  echo "최근 로그 파일을 찾을 수 없거나 비어있습니다 ($(date))." > "$ATTACH_PATH"
fi
ATTACH_NAME=$(basename "$ATTACH_PATH")

# MIME 이메일 작성
BOUNDARY="=====BOUNDARY_$(date +%s)_$$====="
SUBJECT="[AL2023] Memory alert: ${USAGE}% on ${HOSTNAME}"
MIME_FILE="$TMPDIR/mem_watch_mail_$$.eml"

{
  echo "From: ${FROM}"
  echo "To: ${TO}"
  echo "Subject: ${SUBJECT}"
  echo "MIME-Version: 1.0"
  echo "Content-Type: multipart/mixed; boundary=\"$BOUNDARY\""
  echo
  echo "--$BOUNDARY"
  echo "Content-Type: text/plain; charset=UTF-8"
  echo
  echo "메모리 사용량 경고입니다."
  echo "- 호스트: ${HOSTNAME}"
  echo "- 시간: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "- 사용량: ${USAGE}% (임계치: ${THRESHOLD}%)"
  echo
  echo "첨부: 최근 수집 로그(${ATTACH_NAME})"
  echo
  echo "--$BOUNDARY"
  echo "Content-Type: text/plain; name=\"$ATTACH_NAME\""
  echo "Content-Disposition: attachment; filename=\"$ATTACH_NAME\""
  echo "Content-Transfer-Encoding: base64"
  echo
  base64 -w 0 "$ATTACH_PATH"
  echo
  echo "--$BOUNDARY--"
} > "$MIME_FILE"

# SES로 발송 (aws cli가 MIME 파일을 읽어 base64 인코딩하여 전송)
if aws ses send-raw-email --region "$SES_REGION" --raw-message "Data=file://$MIME_FILE" >/dev/null 2>&1; then
  echo "$NOW" > "$LAST_FILE"
  echo "[mem_watch] alert sent to ${TO} with ${ATTACH_NAME}"
else
  echo "[mem_watch] failed to send email via SES"
  exit 1
fi

# 정리
rm -f "$MIME_FILE" 2>/dev/null || true

EOF