#!/bin/bash
# 로컬 실행용 자체 서명(self-signed) 코드 서명 인증서를 만든다.
#
# 왜 필요한가: macOS는 ad-hoc 서명 앱의 화면 기록(ScreenCaptureKit) 권한을
# 안정적으로 기억하지 못해 매 실행마다 권한을 다시 묻는다. 안정적인 인증서로
# 서명하면 TCC가 앱을 동일 앱으로 인식해 권한이 한 번만에 유지된다.
#
# project.yml 의 CODE_SIGN_IDENTITY 와 이름이 일치해야 한다("VtuberTranslate Dev").
set -euo pipefail

CERT_NAME="VtuberTranslate Dev"

if security find-identity -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
  echo "✓ 이미 '$CERT_NAME' 인증서가 있습니다. 건너뜁니다."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.conf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $CERT_NAME
[v3]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
basicConstraints = critical,CA:false
EOF

openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -nodes -config "$TMP/cert.conf" >/dev/null 2>&1

# OpenSSL 3 ↔ Apple 키체인 호환을 위해 레거시 PKCS12 인코딩 사용
openssl pkcs12 -export -legacy -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/cert.p12" \
  -passout pass:vt -name "$CERT_NAME" >/dev/null 2>&1

# -A: codesign이 키체인 접근 프롬프트 없이 키를 쓰도록 허용
security import "$TMP/cert.p12" -k ~/Library/Keychains/login.keychain-db -P vt -A

echo "✓ '$CERT_NAME' 인증서를 로그인 키체인에 생성했습니다."
echo "  이제 xcodegen generate && Xcode에서 빌드하면 이 인증서로 서명됩니다."
