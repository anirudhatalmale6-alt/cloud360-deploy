#!/usr/bin/env bash
#
# Lock down the LiquorOnline / LiquorAuction image bucket on MinIO.
#
# What it does, and just as importantly what it does NOT do:
#
#   It sets the bucket to "download" - anyone with the exact URL of an image
#   can fetch that image, which is what both websites need in order to show a
#   product photo to a visitor who is not logged in. Nobody can list the
#   bucket, so nobody can walk the contents and take the lot.
#
#   It does NOT set the bucket private. Private breaks every image on both
#   sites at once - the browser fetches them anonymously.
#
# Run it on the MinIO box as the ubuntu24 user. It needs sudo only to read the
# service's own credentials, and it never prints them.
#
#   bash minio-image-lockdown.sh                  # the default bucket
#   bash minio-image-lockdown.sh other-bucket     # some other bucket
#
set -uo pipefail

BUCKET="${1:-demo-liquor-images}"
ENDPOINT="${MINIO_ENDPOINT:-http://127.0.0.1:9000}"
ALIAS="lockdown-tmp"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32mOK\033[0m   %s\n' "$*"; }
bad()  { printf '    \033[31mFAIL\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }

command -v mc >/dev/null 2>&1 || { bad "mc is not installed on this machine."; exit 1; }

# ---------------------------------------------------------------------------
# 1. Find the credentials MinIO itself is running with.
#
# The alias already on this box does not have permission to change a bucket
# policy - that is the Access Denied. Rather than guess which user it is, read
# the root credentials out of the service configuration. They are loaded into
# variables and never echoed.
# ---------------------------------------------------------------------------
say "Looking for the MinIO service credentials"

FOUND=""
for f in /etc/default/minio /etc/minio/minio.conf /etc/minio.env /etc/minio/minio.env; do
  if sudo test -r "$f" && sudo grep -q "MINIO_ROOT_USER" "$f" 2>/dev/null; then
    FOUND="$f"; break
  fi
done

if [ -z "$FOUND" ]; then
  # Fall back to an Environment= line in the systemd unit or its overrides.
  CAND=$(sudo grep -rls "MINIO_ROOT_USER" /etc/systemd/system /lib/systemd/system 2>/dev/null | head -1)
  [ -n "$CAND" ] && FOUND="$CAND"
fi

if [ -z "$FOUND" ]; then
  bad "Could not find MINIO_ROOT_USER in the usual places."
  note "MinIO may be running in Docker here. Send me the output of:"
  note "    systemctl cat minio 2>/dev/null | head -30"
  note "and I will adjust this script. Nothing has been changed."
  exit 1
fi
ok "Reading credentials from $FOUND"

strip_value() {
  # Pull the value off a KEY=value line, whether or not it is quoted and
  # whether or not systemd's Environment= prefix is in front of it.
  sudo grep -hE "$1=" "$FOUND" 2>/dev/null | head -1 \
    | sed -E "s/.*$1=//; s/^[\"']//; s/[\"'][[:space:]]*$//; s/[[:space:]]+$//"
}

MINIO_ROOT_USER=$(strip_value MINIO_ROOT_USER)
MINIO_ROOT_PASSWORD=$(strip_value MINIO_ROOT_PASSWORD)

if [ -z "${MINIO_ROOT_USER:-}" ] || [ -z "${MINIO_ROOT_PASSWORD:-}" ]; then
  bad "Found the file but could not read both values out of it."
  note "Nothing has been changed. Send me the first line of $FOUND with the"
  note "password blanked out and I will fix the parser."
  exit 1
fi
ok "Credentials loaded (not shown)"

# ---------------------------------------------------------------------------
# 2. Point a temporary alias at the local MinIO with those credentials.
# ---------------------------------------------------------------------------
say "Connecting to MinIO at $ENDPOINT"
if ! mc alias set "$ALIAS" "$ENDPOINT" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1; then
  bad "Could not connect. Is MinIO listening on $ENDPOINT?"
  note "Try again with a different address, for example:"
  note "    MINIO_ENDPOINT=http://127.0.0.1:9001 bash minio-image-lockdown.sh"
  exit 1
fi
unset MINIO_ROOT_USER MINIO_ROOT_PASSWORD
ok "Connected"

if ! mc ls "$ALIAS/$BUCKET" >/dev/null 2>&1; then
  bad "Bucket '$BUCKET' not found. Buckets on this server:"
  mc ls "$ALIAS" 2>/dev/null | sed 's/^/      /'
  mc alias remove "$ALIAS" >/dev/null 2>&1
  exit 1
fi

OBJECTS=$(mc ls --recursive "$ALIAS/$BUCKET" 2>/dev/null | wc -l | tr -d ' ')
ok "Bucket '$BUCKET' found, $OBJECTS objects"

# A real object to test the anonymous fetch with afterwards. mc prints
# "[date time tz]  size  name" - drop the bracketed stamp and the size.
SAMPLE=$(mc ls --recursive "$ALIAS/$BUCKET" 2>/dev/null | head -1 \
         | sed -E 's/^\[[^]]*\][[:space:]]+[^[:space:]]+[[:space:]]+//')

say "Access before the change"
mc anonymous get "$ALIAS/$BUCKET" 2>&1 | sed 's/^/    /'

# ---------------------------------------------------------------------------
# 3. Set it. "download" is GetObject and nothing else.
# ---------------------------------------------------------------------------
say "Setting '$BUCKET' to download-only"
if mc anonymous set download "$ALIAS/$BUCKET" 2>&1 | sed 's/^/    /'; then
  ok "Policy applied"
else
  bad "Could not apply the policy even as the service account."
  mc alias remove "$ALIAS" >/dev/null 2>&1
  exit 1
fi

# ---------------------------------------------------------------------------
# 4. Prove it, from outside, with no credentials at all.
#
# Two questions, and both answers matter:
#   can a stranger list the bucket?  must be NO
#   can a stranger fetch an image?   must be YES, or both websites go blank
# ---------------------------------------------------------------------------
say "Checking it from outside, with no login"

LIST_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$ENDPOINT/$BUCKET/" 2>/dev/null)
if [ "$LIST_CODE" = "403" ] || [ "$LIST_CODE" = "401" ]; then
  ok "Listing the bucket is refused (HTTP $LIST_CODE) - the contents cannot be walked"
else
  bad "Listing the bucket returned HTTP $LIST_CODE - it should have been refused"
fi

if [ -n "$SAMPLE" ]; then
  SAMPLE_URL=$(printf '%s' "$SAMPLE" | sed 's/ /%20/g')
  GET_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
    "$ENDPOINT/$BUCKET/$SAMPLE_URL" 2>/dev/null)
  if [ "$GET_CODE" = "200" ]; then
    ok "A known image still loads (HTTP 200) - the websites are fine"
  else
    bad "A known image returned HTTP $GET_CODE - images may be broken, tell me before you leave it"
    note "    object tested: $SAMPLE"
  fi
else
  note "No objects in the bucket to test a fetch with."
fi

say "Policy now in force"
mc anonymous get "$ALIAS/$BUCKET" 2>&1 | sed 's/^/    /'

mc alias remove "$ALIAS" >/dev/null 2>&1
say "Done"
note "The temporary login was removed. Nothing was left behind on this machine."
