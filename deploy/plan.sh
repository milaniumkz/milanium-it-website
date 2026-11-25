#!/bin/sh
# Read-only by default. Never deploys or contacts the registry.
set -eu
if [ "$#" -ne 0 ]; then
  printf '%s\n' 'Использование: sh deploy/plan.sh' >&2
  exit 2
fi
cd -- "$(dirname -- "$0")"
unset MILANIUM_IMAGE MILANIUM_HOST_PORT MILANIUM_CONTAINER_PORT
python3 validate.py .env
docker compose --env-file .env -p milanium-web -f compose.yaml config --quiet
printf '%s\n' 'Compose-конфигурация корректна. Сервер, порт и запуск не проверялись.'
