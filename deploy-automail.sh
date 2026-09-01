#!/bin/sh
# AutoMail - turn the scheduler on.
#
# Until now nothing on this server ever picked up a scheduled campaign or a
# drip sequence. This installs the code that does, adds the database columns
# it needs, and sets up the five-minute timer that drives it.
#
# It looks at the database change BEFORE applying it and refuses to run if
# anything in it would delete data. Safe to run more than once.

# This needs root: it switches user to run the build, hands files back to their
# owner, and installs a timer. Run without it and every one of those fails
# separately, twelve lines apart, and none of them says the actual reason.
if [ "$(id -u)" != 0 ]; then
  echo "This has to run as root. Run it again as:"
  echo ""
  echo "    sudo bash deploy-automail.sh"
  echo ""
  echo "Nothing has been changed."
  exit 1
fi

# Every log this run writes goes in its own new directory.
#
# They used to be fixed names in /tmp. A run as root left them owned by root,
# the next run as an ordinary user could not write them - and then printed the
# PREVIOUS run's log as the explanation for this run's failure. That is worse
# than no log at all: it was a real git pull, with a real file count, belonging
# to a different day. A fresh directory per run cannot do that.
WORK=$(mktemp -d /tmp/automail-run.XXXXXX) || {
  echo "Could not create a working directory under /tmp. Nothing has been changed."
  exit 1
}
REPORT="$WORK/report.txt"
: > "$REPORT" || { echo "Could not write to $REPORT. Nothing has been changed."; exit 1; }

say()  { echo "$@"; echo "$@" >> "$REPORT"; }
hide() { sed -E 's/gh[pous]_[A-Za-z0-9_]*/HIDDEN/g'; }
quote(){ hide | sed 's/^/     | /' | tee -a "$REPORT"; }

WARN=""
warn() { WARN="$WARN
  - $1"; }

say "==== AutoMail scheduler - $(date) ===="
say ""

# ---------------------------------------------------------------- find it
say "1/9  finding AutoMail"
DIR=""
for base in /opt /root /home /srv /var/www /usr/local; do
  [ -d "$base" ] || continue
  for f in $(find "$base" -maxdepth 5 -name package.json -not -path '*/node_modules/*' 2>/dev/null); do
    if grep -q '"cloud360-automail"' "$f" 2>/dev/null; then DIR=$(dirname "$f"); break; fi
  done
  [ -n "$DIR" ] && break
done
if [ -z "$DIR" ]; then
  say "REPORT BACK - could not find the AutoMail folder."
  exit 1
fi
OWNER=$(stat -c %U "$DIR")
GROUP=$(stat -c %G "$DIR")
say "     $DIR   (owned by $OWNER)"
cd "$DIR" || exit 1

asowner() { runuser -l "$OWNER" -c "cd '$DIR' && $1"; }

# mktemp made this readable by root only, and some of the work below runs as
# $OWNER and writes into it. Opened to $OWNER and nobody else - git's own
# chatter can carry an access token, so this does not become world-readable.
chown "$OWNER":"$GROUP" "$WORK" 2>/dev/null
chmod 750 "$WORK"

say "     disk    $(df -Ph . | awk 'NR==2{print $4" free of "$2}')"
say "     memory  $(free -m | awk '/^Mem/{print $7" MB available of "$2" MB"}')"
say "     node    $(node -v 2>/dev/null || echo unknown)"

FREE_KB=$(df -Pk . | awk 'NR==2{print $4}')
if [ "$FREE_KB" -lt 2097152 ]; then
  say ""
  say "REPORT BACK - only $((FREE_KB/1024)) MB free, a build needs about 2 GB."
  say "Nothing was changed."
  exit 1
fi

# ------------------------------------------------------------- get the code
say ""
say "2/9  getting the new code"
if [ ! -d .git ] || [ -z "$(git remote 2>/dev/null)" ]; then
  say "REPORT BACK - this folder is not connected to a code repository."
  exit 1
fi
git config --global --add safe.directory "$DIR" >/dev/null 2>&1
BEFORE=$(git rev-parse --short HEAD 2>/dev/null)
if asowner 'git pull --ff-only' > $WORK/pull.log 2>&1; then
  say "     code $BEFORE -> $(git rev-parse --short HEAD)"
else
  say "REPORT BACK - could not fetch the new code. Reason:"
  tail -n 6 $WORK/pull.log | quote
  exit 1
fi

if [ ! -f src/lib/campaign-sender.ts ]; then
  say "REPORT BACK - the new scheduler is not in the code that was pulled."
  exit 1
fi
# The named report for the read-only login. Checked by name so a pull that
# quietly did nothing is caught here rather than after a ten-minute build.
if [ ! -f src/app/api/reports/engagement/route.ts ]; then
  say "REPORT BACK - the named campaign report is not in the code that was pulled."
  say "That means this folder is behind. Nothing has been changed."
  exit 1
fi

# ------------------------------------------------------------- the settings
# Two settings are needed. Both are generated here and written straight into
# .env on this machine - they are never printed and never leave the server.
say ""
say "3/9  settings"
touch .env
chown "$OWNER":"$GROUP" .env 2>/dev/null
chmod 600 .env

addsetting() {
  KEY=$1
  if grep -q "^$KEY=" .env 2>/dev/null; then
    say "     $KEY already set - left alone"
  else
    VALUE=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
    printf '%s=%s\n' "$KEY" "$VALUE" >> .env
    say "     $KEY generated and saved"
  fi
}
addsetting CRON_SECRET
addsetting TRACKING_SECRET

if ! grep -q '^NEXT_PUBLIC_APP_URL=' .env 2>/dev/null; then
  printf 'NEXT_PUBLIC_APP_URL=%s\n' "https://automail.cloud360.ca" >> .env
  say "     NEXT_PUBLIC_APP_URL set to https://automail.cloud360.ca"
else
  say "     NEXT_PUBLIC_APP_URL already set - left alone"
fi

if ! grep -q '^DATABASE_URL=' .env 2>/dev/null; then
  say "REPORT BACK - there is no DATABASE_URL in .env, so nothing can reach the database."
  exit 1
fi

# --------------------------------------------------------- database change
say ""
say "4/9  working out what the database needs"
asowner 'npx --yes prisma generate' > $WORK/prisma.log 2>&1 \
  || { say "REPORT BACK - prisma generate failed:"; tail -n 15 $WORK/prisma.log | quote; exit 1; }

# Double quotes, so $WORK is this script's directory and not an empty variable
# inside the other user's shell - which would have written to /migration.sql.
if ! asowner "npx --yes prisma migrate diff --from-config-datasource --to-schema prisma/schema.prisma --script > $WORK/migration.sql" 2>$WORK/diff.log; then
  say "REPORT BACK - could not work out the database change:"
  tail -n 15 $WORK/diff.log | quote
  exit 1
fi

if [ ! -s $WORK/migration.sql ]; then
  say "     nothing to change - the database is already up to date"
else
  # Anything that removes data stops this script. An additive change adds
  # columns and a table; it never drops or empties one.
  DANGER=$(grep -icE 'DROP TABLE|DROP COLUMN|DROP DATABASE|DROP SCHEMA|TRUNCATE|ALTER TABLE [^;]*DROP ' $WORK/migration.sql)
  ADDS=$(grep -cE 'ADD COLUMN|CREATE TABLE|CREATE INDEX|CREATE TYPE|ADD VALUE' $WORK/migration.sql)
  say "     $ADDS additions, $DANGER changes that would remove data"
  if [ "$DANGER" -ne 0 ]; then
    say ""
    say "REPORT BACK - the database change would delete something. Stopping."
    say "Nothing was changed. The change it wanted to make was:"
    grep -iE 'DROP|TRUNCATE' $WORK/migration.sql | head -n 10 | quote
    exit 1
  fi

  say ""
  say "5/9  applying it"
  if asowner "npx --yes prisma db execute --file $WORK/migration.sql" > $WORK/apply.log 2>&1; then
    say "     applied"
  else
    say "REPORT BACK - the database change failed:"
    tail -n 15 $WORK/apply.log | quote
    exit 1
  fi
fi

# ------------------------------------------------------------------- build
say ""
say "6/9  building"

# One build run as root leaves root-owned files behind, and every later build
# as $OWNER then dies trying to overwrite them. .next is deleted outright below
# so it cannot bite here, but node_modules is not - and npm install as $OWNER
# into a root-owned tree fails in a way that reads like a broken package.
# We are root at this point, so this is just a chown; no password, no prompt.
# Counted through a function that refuses to answer 0 when find itself failed.
# Swallowing find's error would turn "I could not check" into "nothing wrong",
# which is the same answer a clean tree gives and the reason this needs saying.
strays() {
  if find node_modules ! -user "$OWNER" > $WORK/stray.txt 2>$WORK/stray.err; then
    wc -l < $WORK/stray.txt
  else
    echo BROKEN
  fi
}

if [ -d node_modules ]; then
  STRAY=$(strays)
  if [ "$STRAY" = BROKEN ]; then
    say "REPORT BACK - could not check who owns the files under node_modules."
    tail -n 3 $WORK/stray.err | quote
    say "Nothing has been changed and AutoMail is still running as it was."
    exit 1
  fi
  if [ "$STRAY" -gt 0 ]; then
    say "     $STRAY files under node_modules are not owned by $OWNER - handing them back"
    chown -R "$OWNER":"$GROUP" node_modules >/dev/null 2>&1
    # Count again rather than trusting the exit code above.
    LEFT=$(strays)
    if [ "$LEFT" != 0 ]; then
      say "REPORT BACK - $LEFT files under node_modules still belong to somebody else."
      say "Nothing has been changed and AutoMail is still running as it was."
      exit 1
    fi
    say "     handed back"
  fi
fi

[ -d node_modules ] || asowner 'npm install --no-audit --no-fund' > $WORK/build.log 2>&1

rm -rf .next
MEM_MB=$(free -m | awk '/^Mem/{print $2}')
HEAP=$((MEM_MB * 3 / 4))
[ "$HEAP" -lt 1024 ] && HEAP=1024
[ "$HEAP" -gt 4096 ] && HEAP=4096

BUILD="NODE_ENV=production NODE_OPTIONS=--max-old-space-size=$HEAP npx --yes next build"
if asowner "$BUILD" > $WORK/build.log 2>&1; then
  say "     build finished"
else
  say "     first attempt failed, reinstalling dependencies and trying again ..."
  asowner 'npm install --no-audit --no-fund' >> $WORK/build.log 2>&1
  if asowner "$BUILD" >> $WORK/build.log 2>&1; then
    say "     build finished on the second attempt"
  else
    say "REPORT BACK - the build failed. It ended with:"
    tail -n 25 $WORK/build.log | quote
    exit 1
  fi
fi

CHUNKS=$(find .next/static/chunks -type f -name '*.js' 2>/dev/null | wc -l)
if [ "$CHUNKS" -lt 5 ]; then
  say "REPORT BACK - the build produced almost nothing ($CHUNKS files)."
  tail -n 25 $WORK/build.log | quote
  exit 1
fi
say "     $CHUNKS files built"

chown -R "$OWNER":"$GROUP" .next 2>/dev/null
find .next -type d -exec chmod 755 {} + 2>/dev/null
find .next -type f -exec chmod 644 {} + 2>/dev/null

# ---------------------------------------------------------------- restart
say ""
say "7/9  restarting AutoMail"
APP=$(runuser -l "$OWNER" -c 'npx --yes pm2 jlist' 2>/dev/null | tr ',' '\n' | grep -oE '"name":"[^"]*automail[^"]*"' | head -1 | cut -d'"' -f4)
[ -z "$APP" ] && APP=cloud360-automail
asowner "npx --yes pm2 restart $APP --update-env" >/dev/null 2>&1 \
  || asowner "npx --yes pm2 start npm --name $APP -- start" >/dev/null 2>&1 \
  || say "     REPORT BACK - could not restart it."
asowner 'npx --yes pm2 save' >/dev/null 2>&1
sleep 8

PORT=""
for p in 3000 3001 3002 8080 8000; do
  if curl -s -o /dev/null --max-time 5 "http://127.0.0.1:$p/login"; then PORT=$p; break; fi
done
if [ -z "$PORT" ]; then
  say "     REPORT BACK - AutoMail is not answering on this machine."
  L=$(ls -1t "/home/$OWNER/.pm2/logs/"*error*.log /root/.pm2/logs/*error*.log 2>/dev/null | head -1)
  [ -n "$L" ] && tail -n 20 "$L" | quote
  exit 1
fi
say "     answering on port $PORT"

# ------------------------------------------------------------- the timer
say ""
say "8/9  setting up the five-minute timer"
SECRET=$(grep '^CRON_SECRET=' .env | head -1 | cut -d= -f2-)

# The secret lives in a root-only wrapper rather than in the crontab line, so
# it is not sitting in a file that lists every scheduled job on the machine.
cat > /usr/local/bin/automail-tick <<TICKEOF
#!/bin/sh
curl -fsS -m 280 -H "x-cron-secret: $SECRET" "http://127.0.0.1:$PORT/api/cron/tick" >> /var/log/automail-tick.log 2>&1
TICKEOF
chmod 700 /usr/local/bin/automail-tick
touch /var/log/automail-tick.log

CRONLINE='*/5 * * * * /usr/local/bin/automail-tick'
( crontab -l 2>/dev/null | grep -v 'automail-tick' ; echo "$CRONLINE" ) | crontab -
if crontab -l 2>/dev/null | grep -q automail-tick; then
  say "     the scheduler will run every 5 minutes"
else
  say "     REPORT BACK - could not install the timer."
  warn "the timer is not installed, so scheduled campaigns still will not send"
fi

# ------------------------------------------------------------- prove it
say ""
say "9/9  proving it works"
BASE="http://127.0.0.1:$PORT"

NOAUTH=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$BASE/api/cron/tick")
say "     without the secret the scheduler answers $NOAUTH  (401 is what we want)"
[ "$NOAUTH" = "401" ] || warn "the scheduler answered $NOAUTH to a request with no secret - it should refuse"

OUT=$(curl -s --max-time 280 -H "x-cron-secret: $SECRET" "$BASE/api/cron/tick")
if echo "$OUT" | grep -q '"ok":true'; then
  SENT=$(echo "$OUT" | grep -oE '"sent":[0-9]+' | tail -1 | cut -d: -f2)
  say "     a real run worked. Emails sent on this first run: ${SENT:-0}"
else
  say "     REPORT BACK - the scheduler ran but did not report success:"
  echo "$OUT" | head -c 600 | quote
  warn "the scheduler did not run cleanly"
fi

say ""
say "-------------------- COPY FROM HERE --------------------"
if [ -z "$WARN" ]; then
  say "DONE. Scheduled campaigns and drip sequences now send on their own,"
  say "checked every 5 minutes."
  say "Click a campaign name in the Campaigns list to see who it went to,"
  say "when, who opened it and who clicked."
else
  say "PARTLY DONE. Still wrong:"
  echo "$WARN" | sed '/^$/d' | tee -a "$REPORT"
  say "The full log of this run is in $WORK"
fi
say "--------------------- TO HERE --------------------------"
