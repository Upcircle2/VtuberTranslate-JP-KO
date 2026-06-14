#!/usr/bin/env bash
# 다운로드 재테스트용 — 로컬에 받아진 음성 모델·설치된 앱·앱 설정을 지워
# "처음 설치" 상태로 되돌린다. (방송 데이터는 건드리지 않음)
#
# 사용법: bash reset-local.sh   (또는 ./reset-local.sh)

set -u
APP_ID="com.sswv.VtuberTranslate"
MODELS="$HOME/Library/Application Support/FluidAudio"

echo "▶ FluidAudio 음성 모델 캐시 삭제 (parakeet/VAD/CTC)…"
if [ -d "$MODELS" ]; then
  du -sh "$MODELS" 2>/dev/null
  rm -rf "$MODELS"
  echo "  삭제됨: $MODELS"
else
  echo "  없음(이미 삭제됨): $MODELS"
fi

echo "▶ 설치된 앱 삭제…"
for p in "$HOME/Applications/VtuberTranslate.app" "/Applications/VtuberTranslate.app"; do
  if [ -d "$p" ]; then rm -rf "$p" && echo "  삭제됨: $p"; fi
done
echo "  (다운로드 폴더 등 다른 위치의 앱은 직접 휴지통으로 옮겨주세요)"

echo "▶ 앱 설정(UserDefaults) 초기화…"
defaults delete "$APP_ID" 2>/dev/null && echo "  초기화됨" || echo "  설정 없음(스킵)"

echo ""
echo "✅ 완료. 앱을 다시 실행하면 음성 모델을 처음부터 다시 받습니다(진행률 % 표시됨)."
echo "   참고: Apple 번역 언어팩(일↔한)은 시스템 관리라 여기서 안 지워집니다."
echo "   필요하면 시스템 설정 → 일반 → 언어 및 지역 → 번역 언어 에서 제거하세요."
