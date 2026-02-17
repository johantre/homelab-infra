#!/bin/bash
# test-hassio-tar.sh - Test hassio-tar.sh decryption on current platform
#
# Usage: ./test-hassio-tar.sh <encrypted.tar.gz> <password>
#
# Tests that the hassio-tar.sh script correctly decrypts SecureTar files.
# Created to catch platform-specific bugs (e.g., uutils dd on ARM64).

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

SCRIPT_DIR="$(dirname "$0")"
HASSIO_TAR="$SCRIPT_DIR/hassio-tar.sh"

if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <encrypted.tar.gz> <password>"
    echo ""
    echo "Example:"
    echo "  tar -xOf backup.tar homeassistant.tar.gz > /tmp/ha.tar.gz"
    echo "  $0 /tmp/ha.tar.gz 'XXXX-XXXX-XXXX-XXXX'"
    exit 1
fi

ENCRYPTED_FILE="$1"
export HASSIO_PASSWORD="$2"

if [ ! -f "$ENCRYPTED_FILE" ]; then
    echo -e "${RED}Error: File not found: $ENCRYPTED_FILE${NC}"
    exit 1
fi

if [ ! -f "$HASSIO_TAR" ]; then
    echo -e "${RED}Error: hassio-tar.sh not found at: $HASSIO_TAR${NC}"
    exit 1
fi

echo "=== Platform Info ==="
uname -m
dd --version 2>&1 | head -1
openssl version
echo ""

echo "=== Testing hassio-tar.sh ==="
echo "Input: $ENCRYPTED_FILE ($(stat -c%s "$ENCRYPTED_FILE") bytes)"
echo ""

# Decrypt and check output
TMP_OUT=$(mktemp)
trap "rm -f $TMP_OUT" EXIT

"$HASSIO_TAR" < "$ENCRYPTED_FILE" > "$TMP_OUT" 2>&1

OUTPUT_SIZE=$(stat -c%s "$TMP_OUT")
echo "Output: $OUTPUT_SIZE bytes"

# Check if output is valid tar
if tar -tf "$TMP_OUT" > /dev/null 2>&1; then
    echo -e "${GREEN}Output is valid tar${NC}"

    # Check for .storage directory
    if tar -tf "$TMP_OUT" 2>/dev/null | grep -q "\.storage/"; then
        echo -e "${GREEN}.storage directory found${NC}"

        # Count files
        FILE_COUNT=$(tar -tf "$TMP_OUT" 2>/dev/null | wc -l)
        echo "Files in archive: $FILE_COUNT"

        echo ""
        echo -e "${GREEN}=== TEST PASSED ===${NC}"
        exit 0
    else
        echo -e "${RED}.storage directory NOT found - likely truncated!${NC}"
        echo ""
        echo "Last 10 files in archive:"
        tar -tf "$TMP_OUT" 2>/dev/null | tail -10
        echo ""
        echo -e "${RED}=== TEST FAILED ===${NC}"
        exit 1
    fi
else
    echo -e "${RED}Output is NOT valid tar${NC}"
    echo "First 100 bytes:"
    head -c 100 "$TMP_OUT" | xxd
    echo ""
    echo -e "${RED}=== TEST FAILED ===${NC}"
    exit 1
fi
