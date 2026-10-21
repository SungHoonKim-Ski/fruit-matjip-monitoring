#!/usr/bin/env bash
# ============================================================
# Grafana 규칙·대시보드가 참조하는 onuljang_* 메트릭 이름이
# BE 코드(fruit-matjip-be)에 실존하는지 grep으로 대조한다.
#
# 사용: BE_SRC=<fruit-matjip-be 루트> scripts/check-metric-names.sh
#   - 기본 BE_SRC: ../fruit-matjip-be/main (워크스페이스 격리 구조 기준)
#   - 종료 코드 0: 전부 실존 / 1: 누락 있음 / 2: 경로 오류
#
# 배경: BE가 메트릭 이름을 바꿔도(onuljang_payments_total → *_success/_failure,
#       onuljang_active_courier_orders → onuljang_courier_tracking_gauge)
#       규칙은 조용히 빈 결과만 내고 아무도 울지 않았다.
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BE_SRC="${BE_SRC:-${ROOT}/../fruit-matjip-be/main}"
BE_JAVA="${BE_SRC}/src/main/java"

if [ ! -d "$BE_JAVA" ]; then
  echo "BE 소스를 찾을 수 없습니다: $BE_JAVA (BE_SRC 환경변수로 지정)" >&2
  exit 2
fi

# Micrometer 접미사(_bucket/_count/_sum/_total/_max)를 떼야 Java 등록 이름과 맞는다.
# 단 _total은 Counter 이름 자체에 들어 있으므로 원형도 함께 찾는다.
names=$(grep -rhoE 'onuljang_[a-z0-9_]+' "${ROOT}/grafana/provisioning" | sort -u)

# 검색 자체가 죽은 것이 아닌지 대조: 반드시 있는 이름 하나는 걸려야 한다
if ! grep -rq 'onuljang_orders_total' "$BE_JAVA"; then
  echo "검색 대조 실패: onuljang_orders_total이 BE 코드에서 안 잡힙니다 (경로·grep 확인)" >&2
  exit 2
fi

missing=0
while IFS= read -r name; do
  [ -n "$name" ] || continue
  base="$name"
  for suffix in _bucket _count _sum _max; do
    base="${base%"$suffix"}"
  done
  if grep -rqF "\"$base\"" "$BE_JAVA"; then
    continue
  fi
  echo "누락: $name (BE 코드에 \"$base\" 등록 없음)"
  missing=$((missing + 1))
done <<< "$names"

if [ "$missing" -gt 0 ]; then
  echo "메트릭 이름 불일치 ${missing}건" >&2
  exit 1
fi
echo "onuljang_* 메트릭 이름 전부 BE 코드에 실존 ($(echo "$names" | wc -l | tr -d ' ')건 확인)"
