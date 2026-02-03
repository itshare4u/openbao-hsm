#!/bin/sh
set -e

log() {
  echo "[openbao-hsm] $*"
}

is_true() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

bootstrap_hsm_keys() {
  TOKEN_LABEL="${BAO_HSM_TOKEN_LABEL:-OpenBao}"
  PIN="${BAO_HSM_PIN:-1234}"
  SO_PIN="${BAO_HSM_SO_PIN:-$PIN}"
  KEY_LABEL="${BAO_HSM_KEY_LABEL:-bao-unseal-key}"
  HMAC_LABEL="${BAO_HSM_HMAC_KEY_LABEL:-bao-hmac-key}"
  PKCS11_LIB="${BAO_HSM_LIB:-${PKCS11_LIB:-/usr/local/lib/softhsm/libsofthsm2.so}}"
  RSA_BITS="${BAO_HSM_RSA_BITS:-3072}"

  if ! command -v softhsm2-util >/dev/null 2>&1; then
    log "softhsm2-util not found, skipping HSM bootstrap"
    return 0
  fi

  if ! command -v p11tool >/dev/null 2>&1; then
    log "p11tool not found, skipping HSM bootstrap"
    return 0
  fi

  if ! softhsm2-util --show-slots 2>/dev/null | grep -q "Label: *${TOKEN_LABEL}$"; then
    log "SoftHSM token '${TOKEN_LABEL}' not found, initializing"
    softhsm2-util --init-token --free --label "${TOKEN_LABEL}" --so-pin "${SO_PIN}" --pin "${PIN}"
  fi

  if ! p11tool --provider "${PKCS11_LIB}" --login --set-pin "${PIN}" --list-all "pkcs11:token=${TOKEN_LABEL}" 2>/dev/null | grep -q "object=${KEY_LABEL};type=private"; then
    log "Generating RSA key '${KEY_LABEL}' (${RSA_BITS} bits)"
    p11tool --batch --provider "${PKCS11_LIB}" --login --set-pin "${PIN}" \
      --generate-privkey=rsa --bits "${RSA_BITS}" --label "${KEY_LABEL}" \
      --mark-wrap --mark-decrypt "pkcs11:token=${TOKEN_LABEL}" >/dev/null
  fi

  if ! p11tool --provider "${PKCS11_LIB}" --login --set-pin "${PIN}" --list-all "pkcs11:token=${TOKEN_LABEL}" 2>/dev/null | grep -q "object=${HMAC_LABEL};type=secret-key"; then
    log "Generating HMAC key '${HMAC_LABEL}'"
    SECRET_HEX="$(openssl rand -hex 32)"
    p11tool --batch --provider "${PKCS11_LIB}" --login --set-pin "${PIN}" \
      --write --label "${HMAC_LABEL}" --mark-sign --mark-private --secret-key "${SECRET_HEX}" \
      "pkcs11:token=${TOKEN_LABEL}" >/dev/null
  fi
}

register_plugins() {
  if [ -z "${BAO_ROOT_TOKEN:-}" ]; then
    return 0
  fi

  if ! command -v bao >/dev/null 2>&1; then
    log "bao CLI not found, skipping plugin registration"
    return 0
  fi

  BAO_ADDR="${BAO_ADDR:-http://127.0.0.1:8200}"
  export BAO_ADDR
  export BAO_TOKEN="${BAO_ROOT_TOKEN}"

  i=0
  code=""
  while [ $i -lt 60 ]; do
    code="$(curl -s -o /dev/null -w "%{http_code}" "${BAO_ADDR}/v1/sys/health" || true)"
    if [ "${code}" = "200" ]; then
      break
    fi
    i=$((i+1))
    sleep 1
  done

  if [ "${code}" != "200" ]; then
    log "OpenBao not ready (health ${code}), skipping plugin registration"
    return 0
  fi

  for name in aws gcp azure; do
    bin="/usr/local/lib/openbao/plugins/vault-plugin-secrets-${name}"
    if [ ! -x "${bin}" ]; then
      log "Plugin binary missing: ${bin}"
      continue
    fi

    if ! bao plugin info secret "${name}" >/dev/null 2>&1; then
      sha="$(sha256sum "${bin}" | awk '{print $1}')"
      log "Registering plugin: ${name}"
      bao plugin register -sha256="${sha}" secret "${name}" >/dev/null
    fi

    if ! bao secrets list -format=json 2>/dev/null | grep -q "\"${name}/\""; then
      log "Enabling secrets engine: ${name}"
      bao secrets enable -path="${name}" "${name}" >/dev/null
    fi
  done
}

if is_true "${BAO_HSM_GENERATE_KEY:-}"; then
  bootstrap_hsm_keys
fi

if is_true "${BAO_PLUGIN_AUTO_REGISTER:-true}" && [ -n "${BAO_ROOT_TOKEN:-}" ]; then
  register_plugins &
fi

if command -v docker-entrypoint.sh >/dev/null 2>&1; then
  exec docker-entrypoint.sh "$@"
fi

exec "$@"
