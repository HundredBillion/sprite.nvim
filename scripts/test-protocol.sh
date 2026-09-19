#!/bin/sh
set -eu
: "${SPRITE_SOURCE:?SPRITE_SOURCE must point to the Sprite checkout for protocol integration}"
test -f "$SPRITE_SOURCE/tests/fixtures/surface-list-v1.json"
"${NVIM:-nvim}" -l tests/protocol_fixture.lua
