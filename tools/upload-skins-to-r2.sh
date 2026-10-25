#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$(cd "${SCRIPT_DIR}/../assets/skins" && pwd)"
BUCKET="${1:-}"

if [[ -z "$BUCKET" || ! "$BUCKET" =~ ^[a-z0-9-]{3,63}$ ]]; then
    echo "Usage: $0 <private-r2-bucket-name>" >&2
    exit 2
fi

count="$(find "$SOURCE_DIR" -maxdepth 1 -type f -iname '*.webp' | wc -l | tr -d '[:space:]')"
if [[ "$count" != "211" ]]; then
    echo "Expected 211 original WebP files in $SOURCE_DIR; found ${count:-0}." >&2
    exit 1
fi

command -v wrangler >/dev/null || { echo "Install Wrangler and authenticate to the Kroma Cloudflare account first." >&2; exit 1; }
echo "Uploading 211 private skins to bucket '$BUCKET' under skins/. Existing objects with matching names may be replaced."
for file in "$SOURCE_DIR"/*.webp; do
    name="$(basename "$file")"
    wrangler r2 object put "$BUCKET/skins/$name" --remote --file "$file" --content-type image/webp
done
echo "Uploaded 211 skins. Verify the BUCKET binding on the Kroma API before enabling activation codes."
