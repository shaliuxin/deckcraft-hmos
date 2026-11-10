#!/usr/bin/env bash
# 为 deckcraft-hmos 生成【本地】调试签名（OpenHarmony 本地 CA 链），绑定专属 bundle
# io.github.shaliuxin.deckcraft.hmos。产出 signing/ 下的 .cer/.p12/.p7b，供
# build-profile.json5 引用，用来验证 hvigor 的 SignHap 打包链路。
#
# 注意（GridCraft / VectorCraft 实测）：本地 CA 链签出的 profile 是 issuer=pki_internal，
# SignHap 能通过，但真机 hdc install 会报 9568257 fail to verify pkcs7 file。
# 真机安装必须由 DevEco「File → Project Structure → Signing Configs → 自动签名」
# 为本包名签发 issuer=app_gallery 的 AGC 调试 profile 并回写 build-profile.json5。
set -euo pipefail

DEVECO="${DEVECO_HOME:-/c/Program Files/Huawei/DevEco Studio}"
JAVA="$DEVECO/jbr/bin/java.exe"
SIGTOOL="$DEVECO/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/signing"
BUNDLE="${DC_BUNDLE:-io.github.shaliuxin.deckcraft.hmos}"
KEYALIAS="deckcraft-debug"
# 口令与设备 UDID 不入库：从环境变量读取（本地调试时自行 export）。
#   export DC_KEYPW=... DC_STOREPW=... DC_UID1=<设备UDID> DC_UID2=<设备UDID>
KEYPW="${DC_KEYPW:?请 export DC_KEYPW（本地调试 CA 密钥口令，勿入库）}"
STOREPW="${DC_STOREPW:?请 export DC_STOREPW（本地调试 CA 库口令，勿入库）}"
UID1="${DC_UID1:?请 export DC_UID1（设备 UDID，勿入库）}"
UID2="${DC_UID2:?请 export DC_UID2（设备 UDID，勿入库）}"

mkdir -p "$OUT"
cd "$OUT"
echo "bundle=$BUNDLE out=$OUT"
run() { echo "+ $JAVA -jar $SIGTOOL $*"; "$JAVA" -jar "$SIGTOOL" "$@" 2>&1 | grep -iE "success|error|exception" | tail -2 || true; }

rm -f root.jks root-ca.cer app-sub.jks app-sub-ca.cer app.p12 app-cert.cer profile.jks profile-ca.cer profile-cert.cer app-profile.json app-leaf.pem app-leaf.der deckcraft-debug.p7b
run generate-keypair -keyAlias oh-root-ca -keyAlg ECC -keySize NIST-P-256 \
  -keystoreFile root.jks -keystorePwd "$STOREPW" -keyPwd "$KEYPW"
run generate-ca -keyAlias oh-root-ca -keyAlg ECC -keySize NIST-P-256 -signAlg SHA256withECDSA \
  -subject "C=CN,O=deckcraft,OU=dev,CN=DeckCraft Root CA" \
  -keystoreFile root.jks -keystorePwd "$STOREPW" -keyPwd "$KEYPW" \
  -outFile root-ca.cer
run generate-keypair -keyAlias oh-app-sub-ca -keyAlg ECC -keySize NIST-P-256 \
  -keystoreFile app-sub.jks -keystorePwd "$STOREPW" -keyPwd "$KEYPW"
run generate-ca -keyAlias oh-app-sub-ca -keyAlg ECC -keySize NIST-P-256 -signAlg SHA256withECDSA \
  -issuer "C=CN,O=deckcraft,OU=dev,CN=DeckCraft Root CA" \
  -issuerKeyAlias oh-root-ca -issuerKeyPwd "$KEYPW" -issuerKeystorePwd "$STOREPW" -issuerKeystoreFile root.jks \
  -subject "C=CN,O=deckcraft,OU=dev,CN=DeckCraft App Signing CA" \
  -keystoreFile app-sub.jks -keystorePwd "$STOREPW" -keyPwd "$KEYPW" \
  -outFile app-sub-ca.cer
run generate-keypair -keyAlias "$KEYALIAS" -keyAlg ECC -keySize NIST-P-256 \
  -keystoreFile app.p12 -keystorePwd "$STOREPW" -keyPwd "$KEYPW"
run generate-app-cert -keyAlias "$KEYALIAS" -keyPwd "$KEYPW" \
  -issuer "C=CN,O=deckcraft,OU=dev,CN=DeckCraft App Signing CA" \
  -issuerKeyAlias oh-app-sub-ca -issuerKeyPwd "$KEYPW" -issuerKeystorePwd "$STOREPW" -issuerKeystoreFile app-sub.jks \
  -subject "C=CN,O=deckcraft,OU=dev,CN=deckcraft-hmos" \
  -validity 3650 -signAlg SHA256withECDSA \
  -keystoreFile app.p12 -keystorePwd "$STOREPW" \
  -outForm certChain -rootCaCertFile root-ca.cer -subCaCertFile app-sub-ca.cer \
  -outFile app-cert.cer
run generate-keypair -keyAlias oh-profile-ca -keyAlg ECC -keySize NIST-P-256 \
  -keystoreFile profile.jks -keystorePwd "$STOREPW" -keyPwd "$KEYPW"
run generate-ca -keyAlias oh-profile-ca -keyAlg ECC -keySize NIST-P-256 -signAlg SHA256withECDSA \
  -issuer "C=CN,O=deckcraft,OU=dev,CN=DeckCraft Root CA" \
  -issuerKeyAlias oh-root-ca -issuerKeyPwd "$KEYPW" -issuerKeystorePwd "$STOREPW" -issuerKeystoreFile root.jks \
  -subject "C=CN,O=deckcraft,OU=dev,CN=DeckCraft Profile CA" \
  -keystoreFile profile.jks -keystorePwd "$STOREPW" -keyPwd "$KEYPW" \
  -outFile profile-ca.cer
run generate-profile-cert -keyAlias oh-profile-ca -keyPwd "$KEYPW" \
  -issuer "C=CN,O=deckcraft,OU=dev,CN=DeckCraft Profile CA" \
  -issuerKeyAlias oh-profile-ca -issuerKeyPwd "$KEYPW" -issuerKeystorePwd "$STOREPW" -issuerKeystoreFile profile.jks \
  -subject "C=CN,O=deckcraft,OU=dev,CN=DeckCraft Provision Profile Debug" \
  -validity 3650 -signAlg SHA256withECDSA \
  -rootCaCertFile root-ca.cer -subCaCertFile profile-ca.cer \
  -outForm certChain -keystoreFile profile.jks -keystorePwd "$STOREPW" -outFile profile-cert.cer

NB=$(date -u +%s); NA=$((NB + 3*365*24*3600))
# GridCraft / VectorCraft 实测：development-certificate 必须是【单张 leaf 证书 → DER →
# URL-safe base64（+/ 换 -_，去 padding）】。放整条链会报 Decode Base64 certificate failed，
# 标准 base64 里的 '+' 会报 Illegal base64 character 2b。
awk '/-----BEGIN CERTIFICATE-----/{f=1} f{print} /-----END CERTIFICATE-----/{exit}' app-cert.cer > app-leaf.pem
openssl x509 -in app-leaf.pem -outform DER -out app-leaf.der
APP_B64=$(python -c "import base64;print(base64.urlsafe_b64encode(open('app-leaf.der','rb').read()).decode().rstrip('='))")
cat > app-profile.json <<EOF
{
  "version-name": "0.15.0",
  "version-code": 1500,
  "uuid": "6c1a0e2b-4f3d-4b7a-9c2e-deckcraft01",
  "validity": { "not-before": $NB, "not-after": $NA },
  "type": "debug",
  "bundle-info": {
    "developer-id": "55530755",
    "development-certificate": "$APP_B64",
    "bundle-name": "$BUNDLE",
    "apl": "normal",
    "app-feature": "hos_normal_app",
    "app-identifier": "6917620714977119980"
  },
  "baseapp-info": {},
  "permissions": {},
  "debug-info": { "device-ids": ["$UID1", "$UID2"], "device-id-type": "udid" },
  "acls": { "allowed-acls": [] },
  "app-privilege-capabilities": [],
  "issuer": "pki_internal"
}
EOF

run sign-profile -mode localSign -keyAlias oh-profile-ca -keyPwd "$KEYPW" \
  -profileCertFile profile-cert.cer -inFile app-profile.json \
  -signAlg SHA256withECDSA -keystoreFile profile.jks -keystorePwd "$STOREPW" \
  -outFile deckcraft-debug.p7b

echo "=== 产物 ==="
ls -la "$OUT"/*.cer "$OUT"/*.p12 "$OUT"/*.p7b 2>&1 | tr -d '\r'
echo "=== 校验 p7b ==="
"$JAVA" -jar "$SIGTOOL" verify-profile -inFile "$OUT/deckcraft-debug.p7b" 2>&1 | grep -iE "verifiedPassed|message|bundle-name" | head
