#!/usr/bin/env bash
# ============================================================
# Grafana Daily Report — 매일 07:00 KST cron 실행
# Prometheus API로 수치 조회 → HTML 테이블 + 대시보드 링크 → AWS SES 발송
# ============================================================
set -euo pipefail

# --- 설정 (환경변수 또는 기본값) ---
GRAFANA_URL="${GRAFANA_URL:-http://localhost:3001}"
GRAFANA_API_KEY="${GRAFANA_API_KEY:?GRAFANA_API_KEY 환경변수 필요}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://localhost:9091}"
SES_FROM="${SES_FROM:?SES_FROM 환경변수 필요}"
SES_TO="${SES_TO:?SES_TO 환경변수 필요}"
AWS_REGION="${AWS_REGION:-ap-northeast-2}"
ENV_NAME="${ENV_NAME:-PROD}"
GRAFANA_LINK_BASE="${GRAFANA_LINK_BASE:-http://localhost:3001}"

REPORT_DATE=$(TZ=Asia/Seoul date -d "yesterday" +%Y-%m-%d 2>/dev/null || TZ=Asia/Seoul date -v-1d +%Y-%m-%d)
NOW_KST=$(TZ=Asia/Seoul date +%Y-%m-%d\ %H:%M 2>/dev/null || TZ=Asia/Seoul date +%Y-%m-%d\ %H:%M)

# 24시간 범위 (어제 00:00 ~ 오늘 00:00 KST)
FROM_TS=$(TZ=Asia/Seoul date -d "$REPORT_DATE 00:00:00" +%s000 2>/dev/null || \
          TZ=Asia/Seoul date -j -f "%Y-%m-%d %H:%M:%S" "$REPORT_DATE 00:00:00" +%s000)
TO_TS=$(( FROM_TS + 86400000 ))

echo "[$(date)] Daily report 생성 시작 — $REPORT_DATE"

# --- Prometheus 쿼리 ---
prom_query() {
  local query="$1"
  curl -sf "${PROMETHEUS_URL}/api/v1/query" \
    --data-urlencode "query=$query" \
    --data-urlencode "time=$(( TO_TS / 1000 ))" 2>/dev/null \
    | python3 -c "import sys,json; r=json.load(sys.stdin); print(r['data']['result'][0]['value'][1] if r['data']['result'] else 'N/A')" 2>/dev/null || echo "N/A"
}

total_requests=$(prom_query "sum(increase(http_server_requests_seconds_count[24h]))")
peak_tps=$(prom_query "max_over_time(sum(rate(http_server_requests_seconds_count[1m]))[24h:])")
error_rate=$(prom_query "sum(rate(http_server_requests_seconds_count{status=~\"5..\"}[24h])) / sum(rate(http_server_requests_seconds_count[24h])) * 100")
cpu_peak=$(prom_query "max_over_time(system_cpu_usage[24h]) * 100")
cpu_avg=$(prom_query "avg_over_time(system_cpu_usage[24h]) * 100")
heap_peak=$(prom_query "max_over_time((jvm_memory_used_bytes{area=\"heap\"} / jvm_memory_max_bytes{area=\"heap\"} * 100)[24h:])")
heap_avg=$(prom_query "avg_over_time((jvm_memory_used_bytes{area=\"heap\"} / jvm_memory_max_bytes{area=\"heap\"} * 100)[24h:])")
disk_usage=$(prom_query "disk_free_bytes / disk_total_bytes * 100")
hikari_peak=$(prom_query "max_over_time(hikaricp_connections_active[24h])")
hikari_pending_peak=$(prom_query "max_over_time(hikaricp_connections_pending[24h])")
scheduler_failures=$(prom_query "sum(increase(onuljang_scheduler_duration_seconds_count{result=\"failure\"}[24h]))")
scheduler_total=$(prom_query "sum(increase(onuljang_scheduler_duration_seconds_count[24h]))")
p95_latency=$(prom_query "histogram_quantile(0.95, sum(rate(http_server_requests_seconds_bucket[24h])) by (le)) * 1000")
p99_latency=$(prom_query "histogram_quantile(0.99, sum(rate(http_server_requests_seconds_bucket[24h])) by (le)) * 1000")

fmt() {
  python3 -c "
v='$1'; suffix='$2'
if v == 'N/A': print('N/A')
else:
  f=float(v)
  if f >= 10000: print(f'{f:,.0f}{suffix}')
  elif f >= 100: print(f'{f:.0f}{suffix}')
  else: print(f'{f:.1f}{suffix}')
" 2>/dev/null || echo "$1"
}

# --- 대시보드 링크 ---
LINK_PARAMS="from=${FROM_TS}&to=${TO_TS}&tz=Asia%2FSeoul"
LINK_OVERVIEW="${GRAFANA_LINK_BASE}/d/onuljang-overview?${LINK_PARAMS}"
LINK_JVM="${GRAFANA_LINK_BASE}/d/onuljang-jvm-infra?${LINK_PARAMS}"
LINK_BUSINESS="${GRAFANA_LINK_BASE}/d/onuljang-business?${LINK_PARAMS}"

# --- 색상 판정 ---
color_class() {
  local val="$1" warn="$2" critical="$3"
  python3 -c "
v='$val'
if v == 'N/A': print('normal')
else:
  f=float(v)
  if f >= $critical: print('critical')
  elif f >= $warn: print('warn')
  else: print('success')
" 2>/dev/null || echo "normal"
}

cpu_class=$(color_class "$cpu_peak" 80 90)
heap_class=$(color_class "$heap_peak" 80 85)
error_class=$(color_class "$error_rate" 0.5 1)
sched_fail_class=$(color_class "$scheduler_failures" 0.5 0.5)
hikari_pend_class=$(color_class "$hikari_pending_peak" 3 5)

# --- HTML 생성 ---
HTML=$(cat <<HTMLEOF
<!DOCTYPE html>
<html><head><meta charset="UTF-8">
<style>
body{font-family:'Apple SD Gothic Neo',sans-serif;margin:20px;color:#333;max-width:650px;}
h1{color:#1a237e;font-size:20px;margin-bottom:4px;}
h2{color:#1a237e;border-bottom:2px solid #1a237e;padding-bottom:6px;font-size:15px;margin-top:24px;}
.subtitle{color:#666;font-size:12px;margin-bottom:16px;}
table{border-collapse:collapse;width:100%;margin-bottom:12px;}
th{background:#e8eaf6;padding:8px 10px;text-align:left;border:1px solid #c5cae9;font-size:13px;}
td{padding:8px 10px;border:1px solid #e0e0e0;font-size:13px;}
.critical{color:#d32f2f;font-weight:bold;}
.warn{color:#f57c00;font-weight:bold;}
.success{color:#388e3c;}
.normal{color:#333;}
.link-box{background:#f5f5f5;border:1px solid #e0e0e0;border-radius:6px;padding:12px 16px;margin:8px 0;}
.link-box a{color:#1565c0;text-decoration:none;font-size:13px;display:block;margin:4px 0;}
.link-box a:hover{text-decoration:underline;}
.footer{color:#999;font-size:11px;margin-top:24px;border-top:1px solid #eee;padding-top:8px;}
</style></head><body>

<h1>[${ENV_NAME}] 과일맛집 일간 모니터링 리포트</h1>
<div class="subtitle">${REPORT_DATE} (어제 00:00 ~ 24:00 KST)</div>

<h2>트래픽</h2>
<table>
<tr><td>총 요청 수</td><td>$(fmt "$total_requests" "건")</td></tr>
<tr><td>Peak TPS</td><td>$(fmt "$peak_tps" " req/s")</td></tr>
<tr><td>HTTP 5xx 에러율</td><td class="${error_class}">$(fmt "$error_rate" "%")</td></tr>
<tr><td>응답 Latency (p95 / p99)</td><td>$(fmt "$p95_latency" "ms") / $(fmt "$p99_latency" "ms")</td></tr>
</table>

<h2>서버 상태</h2>
<table>
<tr><th>항목</th><th>Peak</th><th>Avg</th></tr>
<tr><td>CPU</td><td class="${cpu_class}">$(fmt "$cpu_peak" "%")</td><td>$(fmt "$cpu_avg" "%")</td></tr>
<tr><td>Heap Memory</td><td class="${heap_class}">$(fmt "$heap_peak" "%")</td><td>$(fmt "$heap_avg" "%")</td></tr>
</table>
<table>
<tr><td>HikariCP Active (Peak)</td><td>$(fmt "$hikari_peak" "")</td></tr>
<tr><td>HikariCP Pending (Peak)</td><td class="${hikari_pend_class}">$(fmt "$hikari_pending_peak" "")</td></tr>
</table>

<h2>스케줄러</h2>
<table>
<tr><td>총 실행</td><td>$(fmt "$scheduler_total" "건")</td></tr>
<tr><td>실패</td><td class="${sched_fail_class}">$(fmt "$scheduler_failures" "건")</td></tr>
</table>

<h2>대시보드 바로가기</h2>
<div class="link-box">
<a href="${LINK_OVERVIEW}">Overview (트래픽, 에러율, KPI)</a>
<a href="${LINK_JVM}">JVM &amp; Infrastructure (CPU, Memory, HikariCP)</a>
<a href="${LINK_BUSINESS}">Business (스케줄러, 알림, 주문)</a>
</div>

<div class="footer">Generated at ${NOW_KST} KST by Grafana Daily Report</div>
</body></html>
HTMLEOF
)

# --- AWS SES 발송 ---
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

BOUNDARY="boundary-$(date +%s)-$$"
MIME_FILE="$WORK_DIR/email.mime"

cat > "$MIME_FILE" <<MIMEEOF
From: ${SES_FROM}
To: ${SES_TO}
Subject: [${ENV_NAME}] 과일맛집 일간 리포트 — ${REPORT_DATE}
MIME-Version: 1.0
Content-Type: text/html; charset=UTF-8
Content-Transfer-Encoding: 7bit

${HTML}
MIMEEOF

aws ses send-raw-email \
  --region "$AWS_REGION" \
  --raw-message "Data=$(base64 < "$MIME_FILE")" \
  --source "$SES_FROM" \
  --destinations "$SES_TO"

echo "[$(date)] Daily report 발송 완료 — $REPORT_DATE"
