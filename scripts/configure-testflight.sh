#!/usr/bin/env bash
set -euo pipefail

if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI (gh)가 필요합니다: https://cli.github.com/" >&2
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "먼저 gh auth login을 실행해 GitHub에 로그인하세요." >&2
  exit 1
fi

repository="${RELAYCODE_GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"

read -r -p "Apple Team ID (10자): " apple_team_id
read -r -p "App Store Connect Issuer ID: " issuer_id
read -r -p "App Store Connect Key ID (10자): " key_id
read -r -p "다운로드한 AuthKey_*.p8의 절대 경로: " private_key_path

if [[ ! "$apple_team_id" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "Apple Team ID 형식이 올바르지 않습니다." >&2
  exit 1
fi
if [[ ! "$issuer_id" =~ ^[0-9a-fA-F-]{36}$ ]]; then
  echo "Issuer ID 형식이 올바르지 않습니다." >&2
  exit 1
fi
if [[ ! "$key_id" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "Key ID 형식이 올바르지 않습니다." >&2
  exit 1
fi
if [[ ! -f "$private_key_path" ]]; then
  echo "p8 파일을 찾을 수 없습니다: $private_key_path" >&2
  exit 1
fi
if ! openssl pkey -in "$private_key_path" -noout >/dev/null 2>&1; then
  echo "유효한 App Store Connect p8 개인 키가 아닙니다." >&2
  exit 1
fi

echo "GitHub 환경과 암호화된 Secrets를 설정합니다: $repository"
gh api --method PUT "repos/$repository/environments/testflight" >/dev/null
printf '%s' "$apple_team_id" \
  | gh secret set APPLE_TEAM_ID --env testflight --repo "$repository"
printf '%s' "$issuer_id" \
  | gh secret set APP_STORE_CONNECT_ISSUER_ID --env testflight --repo "$repository"
printf '%s' "$key_id" \
  | gh secret set APP_STORE_CONNECT_KEY_ID --env testflight --repo "$repository"
/usr/bin/base64 -i "$private_key_path" \
  | gh secret set APP_STORE_CONNECT_PRIVATE_KEY_BASE64 --env testflight --repo "$repository"

unset apple_team_id issuer_id key_id private_key_path
echo "TestFlight Secrets 설정이 완료되었습니다."
