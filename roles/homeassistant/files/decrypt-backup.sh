#!/bin/bash
set -e

WORK_DIR="$1"
PASSWORD="$2"

cd "$WORK_DIR"

export HASSIO_PASSWORD="$PASSWORD"

# Decrypt direct on target without Ansible interference
bash ./hassio-tar.sh < homeassistant.tar.gz | tar -x

echo "✅ Decrypt complete"