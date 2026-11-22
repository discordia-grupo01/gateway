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
export OTEL_PLUGINS

envsubst < /template/kong.yml.template > /rendered/kong.yml
