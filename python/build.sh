#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

IMAGE_NAME="fastapi-celery-scrapy"
IMAGE_TAG="py310"

cd "${ROOT_DIR}"

docker build \
  -t "${IMAGE_NAME}:${IMAGE_TAG}" \
  -f ./python/Dockerfile \
  ./python

echo "==> Built ${IMAGE_NAME}:${IMAGE_TAG}"
