#!/usr/bin/env bash
# Regenerate IHP types from Application/Schema.sql.
#
# IHP v1.6.0 has a codegen bug: primary-key encoders in Create*/Update*/Fetch*
# statements wrap in `Encoders.nullable` (should be `Encoders.nonNullable`).
# This script regenerates then patches the bug, so the cabal build succeeds.
#
# Run from project root:
#   ./hnvr-web/regen.sh
set -euo pipefail

cd "$(dirname "$0")"

echo "[regen] running IHP schema-compiler (v1.6.0)..."
rm -rf gen build
nix run --accept-flake-config 'github:digitallyinduced/ihp/v1.6.0#schema-compiler'
mv build gen

echo "[regen] patching IHP codegen bug (PK nullable → nonNullable)..."
for f in gen/Generated/Statements/Create*.hs gen/Generated/Statements/Update*.hs gen/Generated/Statements/Fetch*.hs; do
  sed -i 's|Encoders.param (Encoders.nullable Mapping.encoder)|Encoders.param (Encoders.nonNullable Mapping.encoder)|g' "$f"
done

# …but cameras.ptz_home_preset_id IS a Maybe (forward FK to ptz_presets)
# — the blanket PK patch above must not touch it.
for f in gen/Generated/Statements/CreateCamera.hs gen/Generated/Statements/CreateManyCamera.hs gen/Generated/Statements/UpdateCamera.hs; do
  sed -i 's|(.ptzHomePresetId) >$< Encoders.param (Encoders.nonNullable Mapping.encoder)|(.ptzHomePresetId) >$< Encoders.param (Encoders.nullable Mapping.encoder)|g' "$f"
done

echo "[regen] done. $(find gen -name '*.hs' | wc -l) files in gen/"
