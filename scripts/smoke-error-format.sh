#!/usr/bin/env bash
# Smoke test del formato de error unificado: levanta Kong DB-less con la config
# real (kong/kong.yml.template renderizada) y un upstream de mentira, y verifica
# que los errores que genera Kong salgan con el sobre
# {"error":{"code","message","details"}} y que los del upstream pasen intactos.
# Requiere docker y curl. Uso: scripts/smoke-error-format.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUFFIX="$$"
NET="smoke-errfmt-net-$SUFFIX"
UP="smoke-errfmt-upstream-$SUFFIX"
KONG="smoke-errfmt-kong-$SUFFIX"
PORT="${SMOKE_PORT:-18000}"
WORK="$(mktemp -d)"
# docker cp es un binario de Windows en Git Bash: necesita rutas nativas.
WORKN="$(cygpath -m "$WORK" 2>/dev/null || echo "$WORK")"
FAILS=0

cleanup() {
  docker rm -f "$KONG" "$UP" >/dev/null 2>&1
  docker network rm "$NET" >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

export MSYS_NO_PATHCONV=1

# Upstream: responde 400 con un cuerpo propio, para comprobar que Kong no lo toca.
cat > "$WORK/default.conf" <<'CONF'
server {
  listen 8080;
  default_type application/json;
  location / {
    return 400 '{"error":{"code":"UPSTREAM_PASSTHROUGH","message":"viene del upstream","details":{}}}';
  }
}
CONF

# Config de Kong: se renderiza como el CI y se baja el limite del rate limiting
# a 1 por minuto para poder provocar el 429 con dos pedidos. El upstream de
# billing apunta a un puerto cerrado para provocar un 502.
sed -E \
  -e 's#\$\{BILLING_UPSTREAM_URL\}#http://'"$UP"':9#g' \
  -e 's#\$\{[A-Z_]+_UPSTREAM_URL\}#http://'"$UP"':8080#g' \
  -e 's#\$\{JWT_SECRET\}#smoke-secret#g' \
  -e 's#\$\{WEB_ORIGIN\}#https://web.invalid#g' \
  -e 's#\$\{OTEL_PLUGINS\}##g' \
  -e 's#minute: [0-9]+#minute: 1#g' \
  "$ROOT/kong/kong.yml.template" > "$WORK/kong.yml"
if grep -n '\${' "$WORK/kong.yml"; then
  echo "El template tiene una variable sin valor de prueba" >&2
  exit 1
fi

docker network create "$NET" >/dev/null || exit 1
docker create --name "$UP" --network "$NET" nginx:alpine >/dev/null || exit 1
docker cp "$WORKN/default.conf" "$UP:/etc/nginx/conf.d/default.conf" || exit 1
docker start "$UP" >/dev/null || exit 1

docker create --name "$KONG" --network "$NET" -p "$PORT:8000" \
  -e KONG_DATABASE=off \
  -e KONG_DECLARATIVE_CONFIG=/kong.yml \
  -e KONG_PROXY_LISTEN=0.0.0.0:8000 \
  -e KONG_ADMIN_LISTEN=127.0.0.1:8001 \
  -e KONG_ERROR_DEFAULT_TYPE=application/json \
  kong:3.6 >/dev/null || exit 1
docker cp "$WORKN/kong.yml" "$KONG:/kong.yml" || exit 1
docker start "$KONG" >/dev/null || exit 1

BASE="http://127.0.0.1:$PORT"
echo "Esperando a Kong..."
ready=0
for _ in $(seq 1 60); do
  if [ "$(curl -s -o /dev/null -w "%{http_code}" "$BASE/__ready_probe__")" = 404 ]; then ready=1; break; fi
  sleep 1
done
if [ "$ready" != 1 ]; then
  echo "Kong no arrancó" >&2
  docker logs "$KONG" 2>&1 | tail -30 >&2
  exit 1
fi

# req <metodo> <path> [curl args...]: deja STATUS, HEADERS y BODY.
req() {
  local method="$1" path="$2"; shift 2
  STATUS=$(curl -s -X "$method" -D "$WORKN/h" -o "$WORKN/b" -w '%{http_code}' "$@" "$BASE$path")
  HEADERS=$(tr -d '\r' < "$WORK/h")
  BODY=$(cat "$WORK/b")
}

pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; echo "       status=$STATUS body=$BODY"; FAILS=$((FAILS + 1)); }

# expect <descripcion> <status> <code> [details-regex]
expect() {
  local desc="$1" status="$2" code="$3" details="${4:-\{\}}"
  if [ "$STATUS" != "$status" ]; then fail "$desc (status esperado $status)"; return; fi
  if ! echo "$HEADERS" | grep -qi '^content-type: application/json'; then fail "$desc (Content-Type no es JSON)"; return; fi
  if ! echo "$BODY" | grep -Eq '^\{"error":\{"code":"'"$code"'","message":"[^"]+","details":'"$details"'\}\}$'; then
    fail "$desc (cuerpo no cumple el sobre con code=$code)"; return
  fi
  pass "$desc"
}

req GET /v1/servers
expect "401 sin token" 401 UNAUTHORIZED

req GET /v1/servers -H 'Authorization: Bearer token.invalido.x'
expect "401 con token inválido" 401 UNAUTHORIZED

req GET /ruta/que/no/existe -H 'Accept: text/html'
expect "404 sin ruta, aun con Accept text/html" 404 NOT_FOUND

req GET /health/billing
expect "502 con upstream caido" 502 BAD_GATEWAY

req POST /v1/pin/login
first="$STATUS"
req POST /v1/pin/login
expect "429 por rate limit" 429 RATE_LIMITED '\{"retry_after_seconds":[0-9]+\}'
if echo "$HEADERS" | grep -qi '^retry-after:' && echo "$HEADERS" | grep -qi '^x-ratelimit-limit-minute:'; then
  pass "429 conserva Retry-After y X-RateLimit-*"
else
  fail "429 conserva Retry-After y X-RateLimit-*"
fi
[ "$first" != 429 ] && pass "el primer pedido no fue limitado (status $first)" || fail "el primer pedido ya salió 429"

req POST /v1/users
if [ "$STATUS" = 400 ] && [ "$BODY" = '{"error":{"code":"UPSTREAM_PASSTHROUGH","message":"viene del upstream","details":{}}}' ]; then
  pass "el error del upstream pasa intacto"
else
  fail "el error del upstream pasa intacto"
fi

echo
if [ "$FAILS" -gt 0 ]; then
  echo "$FAILS verificación(es) fallaron"
  docker logs "$KONG" 2>&1 | tail -20
  exit 1
fi
echo "Todas las verificaciones pasaron"
