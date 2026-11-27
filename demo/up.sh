#!/usr/bin/env bash
# Start the throwaway demo Documenso (see docker-compose.yml). Safe to re-run; `demo/up.sh down` removes it.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# Docker Compose v2 plugin (`docker compose`) or the standalone binary, whichever this machine has.
if docker compose version >/dev/null 2>&1; then compose=(docker compose); else compose=(docker-compose); fi

if [[ "${1:-}" == "down" ]]; then
  "${compose[@]}" --env-file .env down -v --remove-orphans
  exit 0
fi

# The image the server runs in production, taken from the pin file so screenshots match what ships.
IMAGE="$(awk '$1 == "image:" { print $2; exit }' ../deploy/docker-compose.image.yml)"

mkdir -p secrets
if [[ ! -f .env ]]; then
  {
    echo "DEMO_IMAGE=${IMAGE}"
    echo "DEMO_DB_PASSWORD=$(openssl rand -hex 16)"
    echo "DEMO_SECRET_1=$(openssl rand -base64 32)"
    echo "DEMO_SECRET_2=$(openssl rand -base64 32)"
    echo "DEMO_SECRET_3=$(openssl rand -base64 32)"
    echo "DEMO_CERT_PASSPHRASE=$(openssl rand -hex 12)"
  } > .env
  chmod 600 .env
fi
set -a; . ./.env; set +a

if [[ ! -f secrets/cert.p12 ]]; then
  tmp="$(mktemp -d)"
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/k.pem" -out "$tmp/c.pem" -days 30 \
    -subj "/CN=Demo Signing/O=Harbor Light Studio" >/dev/null 2>&1
  openssl pkcs12 -export -out secrets/cert.p12 -inkey "$tmp/k.pem" -in "$tmp/c.pem" \
    -passout "pass:${DEMO_CERT_PASSPHRASE}" >/dev/null 2>&1
  rm -rf "$tmp"
  chmod 600 secrets/cert.p12
fi

# Hand the certificate to the container as an environment value (see docker-compose.yml).
DEMO_CERT_B64="$(base64 < secrets/cert.p12 | tr -d '\n')"
export DEMO_CERT_B64

"${compose[@]}" --env-file .env up -d --wait --wait-timeout 300
echo "app:  http://127.0.0.1:${DEMO_APP_PORT:-3190}"
echo "mail: http://127.0.0.1:${DEMO_MAIL_PORT:-8125}"
