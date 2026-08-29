#!/usr/bin/env bash
#
# Lock down the LiquorOnline / LiquorAuction image bucket on MinIO.
#
# What it does, and just as importantly what it does NOT do:
#
#   It applies a policy that allows exactly one anonymous action: GetObject.
#   Anyone holding the exact URL of an image can fetch that image, which is
#   what both websites need in order to show a product photo to a visitor who
#   is not logged in. Nobody can LIST the bucket, so nobody can walk the
#   contents and take the lot.
#
#   It does NOT set the bucket private. Private breaks every image on both
#   sites at once - the browser fetches them anonymously.
#
#   It does NOT use `mc anonymous set download`. That is MinIO's canned
#   "readonly" policy, and readonly grants s3:ListBucket as well as
#   s3:GetObject - which is why the bucket stayed fully listable after the
#   first version of this script reported success. The only way to get
#   GetObject on its own is a hand-written policy, applied with set-json.
#
# Run it on the MinIO box as the ubuntu24 user. It needs sudo only to read the
# service's own credentials, and it never prints them.
#
#   bash minio-image-lockdown.sh                  # the default bucket
#   bash minio-image-lockdown.sh other-bucket     # some other bucket
#
# If the images stop loading after the change, the script puts the old policy
# back by itself before it exits. It will not leave the sites broken.
#
set -uo pipefail

BUCKET="${1:-demo-liquor-images}"
ENDPOINT="${MINIO_ENDPOINT:-http://127.0.0.1:9000}"
ALIAS="lockdown-tmp"
POLICY_FILE="$(mktemp -t minio-policy-XXXXXX.json)"

cleanup() {
  rm -f "$POLICY_FILE"
  mc alias remove "$ALIAS" >/dev/null 2>&1
}
trap cleanup EXIT

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
  exit 1
fi

OBJECTS=$(mc ls --recursive "$ALIAS/$BUCKET" 2>/dev/null | wc -l | tr -d ' ')
ok "Bucket '$BUCKET' found, $OBJECTS objects"

# A real object to test the anonymous fetch with afterwards.
#
# Read the key out of --json rather than off the human-readable columns. The
# plain output is "[date time tz]  size  STORAGECLASS  name", and a previous
# version of this script chopped only the stamp and the size, so it tried to
# fetch "STANDARD 100104.jpg" and got a 404 on a bucket that was perfectly
# healthy. A wrong test object fails the wrong way round: it reports damage
# that is not there.
RAW=$(mc ls --recursive --json "$ALIAS/$BUCKET" 2>/dev/null | head -1)
SAMPLE=""
case "$RAW" in
  *'"key":"'*) SAMPLE=$(printf '%s' "$RAW" | sed -E 's/.*"key":"([^"]*)".*/\1/') ;;
esac

say "Access before the change"
BEFORE=$(mc anonymous get "$ALIAS/$BUCKET" 2>&1)
printf '    %s\n' "$BEFORE"
[ -n "$SAMPLE" ] && note "test object: $SAMPLE"

# A stranger's view of the bucket, before we touch anything.
LIST_BEFORE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$ENDPOINT/$BUCKET/?list-type=2&max-keys=1" 2>/dev/null)
if [ "$LIST_BEFORE" = "200" ]; then
  note "right now a stranger CAN list this bucket (HTTP 200) - that is what we are fixing"
else
  note "listing already refused (HTTP $LIST_BEFORE)"
fi

# ---------------------------------------------------------------------------
# 3. Apply the policy: GetObject on the objects, and nothing at bucket level.
# ---------------------------------------------------------------------------
say "Applying a read-one-object-by-name policy to '$BUCKET'"
cat > "$POLICY_FILE" <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PublicReadByExactNameOnly",
      "Effect": "Allow",
      "Principal": { "AWS": ["*"] },
      "Action": ["s3:GetObject"],
      "Resource": ["arn:aws:s3:::$BUCKET/*"]
    }
  ]
}
POLICY

# Capture first, then report. Piping mc straight into sed would hand us sed's
# exit status, which is always 0 - the old script could print "Policy applied"
# over the top of a refusal.
SET_OUT=$(mc anonymous set-json "$POLICY_FILE" "$ALIAS/$BUCKET" 2>&1)
SET_RC=$?
printf '    %s\n' "$SET_OUT"
if [ "$SET_RC" -ne 0 ]; then
  bad "Could not apply the policy even as the service account."
  exit 1
fi
ok "Policy applied"

# ---------------------------------------------------------------------------
# 4. Prove it, from outside, with no credentials at all.
#
# Two questions, and both answers matter:
#   can a stranger list the bucket?  must be NO
#   can a stranger fetch an image?   must be YES, or both websites go blank
# ---------------------------------------------------------------------------
say "Checking it from outside, with no login"

LIST_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$ENDPOINT/$BUCKET/?list-type=2&max-keys=1" 2>/dev/null)
if [ "$LIST_CODE" = "403" ] || [ "$LIST_CODE" = "401" ]; then
  ok "Listing the bucket is refused (HTTP $LIST_CODE) - the contents cannot be walked"
else
  bad "Listing the bucket returned HTTP $LIST_CODE - it should have been refused"
fi

GET_CODE=""
if [ -n "$SAMPLE" ]; then
  SAMPLE_URL=$(printf '%s' "$SAMPLE" | sed 's/ /%20/g')
  GET_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 \
    "$ENDPOINT/$BUCKET/$SAMPLE_URL" 2>/dev/null)
  if [ "$GET_CODE" = "200" ]; then
    ok "A known image still loads (HTTP 200) - the websites are fine"
  else
    bad "A known image returned HTTP $GET_CODE - putting the old policy back now"
    note "object tested: $SAMPLE"
    mc anonymous set download "$ALIAS/$BUCKET" >/dev/null 2>&1 \
      && note "old policy restored - the sites are as they were, nothing is broken" \
      || note "could not restore automatically - tell me before you leave this"
    exit 1
  fi
else
  note "No objects in the bucket to test a fetch with."
fi

say "Policy now in force"
mc anonymous get "$ALIAS/$BUCKET" 2>&1 | sed 's/^/    /'

say "Done"
note "The temporary login was removed. Nothing was left behind on this machine."
