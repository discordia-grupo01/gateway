#!/bin/sh
set -eu

apk add --no-cache gettext >/dev/null

endpoint="${OTEL_EXPORTER_OTLP_ENDPOINT:-}"
api_key="$(printf '%s' "${OTEL_EXPORTER_OTLP_HEADERS:-}" | tr ',' '\n' | sed -n 's/^[[:space:]]*[Aa][Pp][Ii]-[Kk][Ee][Yy][[:space:]]*=[[:space:]]*//p' | head -n 1 | tr -d '[:space:]')"
service_name="${OTEL_SERVICE_NAME:-kong}"

case "$service_name" in
  *[!A-Za-z0-9_.-]*)
    echo "OTEL_SERVICE_NAME solo admite letras, numeros, punto, guion y guion bajo: se usa 'kong'" >&2
    service_name="kong"
    ;;
esac

case "$endpoint" in
  "") ;;
  http://*|https://*) ;;
  *)
    echo "OTEL_EXPORTER_OTLP_ENDPOINT tiene que empezar con http:// o https://: Kong arranca sin trazas" >&2
    endpoint=""
    ;;
esac

case "$api_key" in
  *[!A-Za-z0-9_.-]*)
    echo "La api-key de OTEL_EXPORTER_OTLP_HEADERS tiene caracteres no validos: Kong arranca sin trazas" >&2
    api_key=""
    ;;
esac

OTEL_PLUGINS=""
if [ -n "$endpoint" ] && [ -n "$api_key" ]; then
  export OTEL_TRACES_URL="${endpoint%/}/v1/traces"
  export OTEL_API_KEY="$api_key"
  export OTEL_SERVICE_NAME="$service_name"
  OTEL_PLUGINS="$(envsubst < /template/opentelemetry.yml.template)"
  echo "OpenTelemetry activado: Kong abre la traza y exporta a ${OTEL_TRACES_URL} como '${service_name}'"
else
  echo "OpenTelemetry apagado: sin OTEL_EXPORTER_OTLP_ENDPOINT y una api-key en OTEL_EXPORTER_OTLP_HEADERS"
fi

log_url="${LOG_SHIP_URL:-}"
log_key="$(printf '%s' "${LOG_SHIP_API_KEY:-}" | tr -d '[:space:]')"
if [ -z "$log_key" ]; then
  log_key="$api_key"
fi

case "$log_url" in
  "") ;;
  http://*|https://*) ;;
  *)
    echo "LOG_SHIP_URL tiene que empezar con http:// o https://: Kong arranca sin envio de logs" >&2
    log_url=""
    ;;
esac

case "$log_key" in
  *[!A-Za-z0-9_.-]*)
    echo "La api-key de los logs tiene caracteres no validos: Kong arranca sin envio de logs" >&2
    log_key=""
    ;;
esac

if [ -n "$log_url" ] && [ -n "$log_key" ]; then
  export LOG_SHIP_URL="$log_url"
  export LOG_API_KEY="$log_key"
  export OTEL_SERVICE_NAME="$service_name"
  OTEL_PLUGINS="$(printf '%s\n%s' "$OTEL_PLUGINS" "$(envsubst < /template/http-log.yml.template)")"
  echo "Envio de logs activado: Kong manda sus logs a ${log_url} como '${service_name}'"
else
  echo "Envio de logs apagado: sin LOG_SHIP_URL y una api-key"
fi
export OTEL_PLUGINS

envsubst < /template/kong.yml.template > /rendered/kong.yml
