#!/bin/sh
# Cloud360 panel - the page loads but stays blank.  ROUND 2.
#
# Round 1 told us two things:
#   * .next/static had 3 files in it and no code chunks at all, so the browser
#     was asking for files that were not there.
#   * the panel's own log ends in EADDRINUSE - it could not start because
#     something else was already holding its port. That is why restarting it
#     changed nothing: the old copy never let go.
#
# So this one frees the port first, builds from scratch, refuses to restart
# unless the build actually produced the files, and then proves it.
#
# Safe to run more than once. Nothing is deleted except the build folder,
# which is regenerated.

# Needs root - it frees a port, switches user to build, and hands files back.
if [ "$(id -u)" != 0 ]; then
  echo "This has to run as root. Run it again as:"
  echo ""
  echo "    sudo bash fix-panel.sh"
  echo ""
  echo "Nothing has been changed."
  exit 1
fi

# A new directory per run. Fixed names in /tmp meant a root-owned log from an
# earlier run could not be overwritten by a later one - and the later run then
# quoted the EARLIER run's log as its own explanation. See deploy-automail.sh,
# where that happened.
WORK=$(mktemp -d /tmp/panel-run.XXXXXX) || {
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

say "==== Cloud360 panel repair, round 2 - $(date) ===="
say ""

# ---------------------------------------------------------------- find it
say "1/9  finding the panel folder"
DIR=""
for base in /opt /root /home /srv /var/www /usr/local; do
  [ -d "$base" ] || continue
  F=$(find "$base" -maxdepth 5 -name 'next.config.mjs' -not -path '*/node_modules/*' 2>/dev/null | head -1)
  if [ -n "$F" ] && [ -f "$(dirname "$F")/server.js" ]; then DIR=$(dirname "$F"); break; fi
done
if [ -z "$DIR" ]; then
  say "REPORT BACK - could not find the panel folder."
  exit 1
fi
OWNER=$(stat -c %U "$DIR")
GROUP=$(stat -c %G "$DIR")
say "     $DIR   (owned by $OWNER)"
cd "$DIR" || exit 1

asowner() { runuser -l "$OWNER" -c "cd '$DIR' && $1"; }
PM2="npx --yes pm2"

# The build runs as $OWNER and writes its log into $WORK. Owner only - git's
# chatter can carry an access token.
chown "$OWNER":"$GROUP" "$WORK" 2>/dev/null
chmod 750 "$WORK"

PORT=$(grep -oE "PORT \|\| '[0-9]+'" server.js 2>/dev/null | grep -oE '[0-9]+' | head -1)
[ -z "$PORT" ] && PORT=3000
say "     the panel is supposed to listen on port $PORT"

# ------------------------------------------------------- who has the port
say ""
say "2/9  what is running right now"
$PM2 list 2>/dev/null | sed -n '3,20p' | quote

say "     processes holding port $PORT:"
HOLDERS=""
if command -v ss >/dev/null 2>&1; then
  HOLDERS=$(ss -lptnH "sport = :$PORT" 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u)
fi
if [ -z "$HOLDERS" ] && command -v lsof >/dev/null 2>&1; then
  HOLDERS=$(lsof -t -i ":$PORT" -sTCP:LISTEN 2>/dev/null | sort -u)
fi
if [ -z "$HOLDERS" ]; then
  say "       (nothing is listening - the panel is down, not just blank)"
else
  for p in $HOLDERS; do
    say "       pid $p  started $(ps -o lstart= -p "$p" 2>/dev/null | tr -s ' ')"
    say "         running from  $(readlink -f "/proc/$p/cwd" 2>/dev/null)"
    say "         command       $(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | cut -c1-90)"
  done
fi

# ------------------------------------------------- the login credentials
# After the security fix the panel signs you in with a real session, and the
# key it signs with comes from PANEL_SECRET, or from PANEL_USER/PANEL_PASS.
# If none of those reach the process, every login fails - so check BEFORE
# restarting rather than discovering it afterwards.  Names only, never values.
say ""
say "3/9  the login settings the panel needs"
FOUND_KEYS=""
for f in .env.local .env.production .env; do
  [ -f "$f" ] || continue
  K=$(grep -oE '^[A-Z0-9_]+' "$f" | tr '\n' ' ')
  say "     $f holds: $K"
  FOUND_KEYS="$FOUND_KEYS $K"
done
if [ -n "$HOLDERS" ]; then
  for p in $HOLDERS; do
    K=$(tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -oE '^(PANEL_[A-Z]+|PROXMOX_[A-Z_]+|WASABI_[A-Z_]+|NODE_ENV|PORT)' | tr '\n' ' ')
    [ -n "$K" ] && { say "     the running process has: $K"; FOUND_KEYS="$FOUND_KEYS $K"; }
    NE=$(tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep '^NODE_ENV=' | cut -d= -f2)
    [ -n "$NE" ] && say "     NODE_ENV is currently '$NE'"
    break
  done
fi
case " $FOUND_KEYS " in
  *" PANEL_SECRET "*|*" PANEL_PASS "*) say "     OK - the panel has something to sign sessions with." ;;
  *) say "     PROBLEM - no PANEL_SECRET and no PANEL_PASS anywhere."
     say "     The new login will refuse everyone until one of them is set."
     warn "no PANEL_SECRET / PANEL_PASS found - you will not be able to log in" ;;
esac

# --------------------------------------------------------------- headroom
say ""
say "4/9  room to work"
say "     disk    $(df -Ph . | awk 'NR==2{print $4" free of "$2}')"
say "     memory  $(free -m | awk '/^Mem/{print $7" MB available of "$2" MB"}')"
say "     node    $(node -v 2>/dev/null || echo unknown)"
FREE_KB=$(df -Pk . | awk 'NR==2{print $4}')
if [ "$FREE_KB" -lt 2097152 ]; then
  say ""
  say "REPORT BACK - only $((FREE_KB/1024)) MB free, a build needs about 2 GB."
  say "Nothing was changed. Send me the log in $WORK"
  exit 1
fi

# ------------------------------------------------------- stop it properly
say ""
say "5/9  stopping the old copy and freeing port $PORT"
$PM2 stop cloud360-panel >/dev/null 2>&1
$PM2 delete cloud360-panel >/dev/null 2>&1
sleep 2
# Anything still sitting on the port is an orphan from an earlier start. It is
# the reason the managed copy could never boot, so it has to go. Only node
# processes are touched.
STILL=$(ss -lptnH "sport = :$PORT" 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u)
[ -z "$STILL" ] && command -v lsof >/dev/null 2>&1 && STILL=$(lsof -t -i ":$PORT" -sTCP:LISTEN 2>/dev/null | sort -u)
for p in $STILL; do
  EXE=$(readlink -f "/proc/$p/exe" 2>/dev/null)
  case "$EXE" in
    *node*) say "     ending orphan pid $p ($EXE)"; kill "$p" 2>/dev/null; sleep 3; kill -9 "$p" 2>/dev/null ;;
    *)      say "     leaving pid $p alone - it is not node, it is $EXE"
            warn "port $PORT is held by something that is not the panel: $EXE" ;;
  esac
done
sleep 2
LEFT=$(ss -lptnH "sport = :$PORT" 2>/dev/null | wc -l)
say "     port $PORT is now $([ "$LEFT" -eq 0 ] && echo free || echo STILL TAKEN)"

# ------------------------------------------------------------ build clean
say ""
say "6/9  building the panel from scratch"
if [ -d .git ] && [ -n "$(git remote 2>/dev/null)" ]; then
  git config --global --add safe.directory "$DIR" >/dev/null 2>&1
  BEFORE=$(git rev-parse --short HEAD 2>/dev/null)
  if asowner 'git pull --ff-only' > $WORK/pull.log 2>&1; then
    say "     code $BEFORE -> $(git rev-parse --short HEAD)"
  else
    say "     could not update the code, using what is already here ($BEFORE). Reason:"
    tail -n 4 $WORK/pull.log | quote
  fi
fi

[ -d node_modules ] || asowner 'npm install --no-audit --no-fund' > $WORK/build.log 2>&1

# A half-finished build folder is exactly what was on this box, and Next will
# happily build on top of one and leave the gaps in place. Start empty.
rm -rf .next
say "     old build folder cleared"

MEM_MB=$(free -m | awk '/^Mem/{print $2}')
HEAP=$((MEM_MB * 3 / 4))
[ "$HEAP" -lt 1024 ] && HEAP=1024
[ "$HEAP" -gt 4096 ] && HEAP=4096
say "     building with a ${HEAP} MB memory limit ..."

BUILD="NODE_ENV=production NODE_OPTIONS=--max-old-space-size=$HEAP npx --yes next build"
if asowner "$BUILD" > $WORK/build.log 2>&1; then
  say "     build finished"
else
  say "     first attempt failed, reinstalling dependencies and trying again ..."
  asowner 'npm install --no-audit --no-fund' >> $WORK/build.log 2>&1
  if asowner "$BUILD" >> $WORK/build.log 2>&1; then
    say "     build finished on the second attempt"
  else
    say ""
    say "REPORT BACK - the build failed. It ended with:"
    tail -n 25 $WORK/build.log | quote
    say ""
    say "Send me the log in $WORK - the panel was left stopped."
    exit 1
  fi
fi

# ------------------------------------------------- check the build is real
# Round 1 restarted whatever the build left behind. That was the mistake:
# a build can exit 0 and still leave nothing to serve. Count the files.
say ""
say "7/9  checking the build actually produced the browser's files"
CHUNKS=$(find .next/static/chunks -type f -name '*.js' 2>/dev/null | wc -l)
CSS=$(find .next/static/css -type f -name '*.css' 2>/dev/null | wc -l)
TOTAL=$(find .next/static -type f 2>/dev/null | wc -l)
say "     $CHUNKS javascript chunks, $CSS stylesheets, $TOTAL files in total"
if [ "$CHUNKS" -lt 5 ]; then
  say ""
  say "REPORT BACK - the build says it worked but produced almost nothing."
  say "This is the same fault as before and the cause is in the build log."
  tail -n 30 $WORK/build.log | quote
  say ""
  say "Send me the log in $WORK - the panel was left stopped."
  exit 1
fi

chown -R "$OWNER":"$GROUP" .next 2>/dev/null
find .next -type d -exec chmod 755 {} + 2>/dev/null
find .next -type f -exec chmod 644 {} + 2>/dev/null
if [ -d .next/standalone ]; then
  mkdir -p .next/standalone/.next
  cp -r .next/static .next/standalone/.next/ 2>/dev/null
  [ -d public ] && cp -r public .next/standalone/ 2>/dev/null
  chown -R "$OWNER":"$GROUP" .next/standalone 2>/dev/null
  say "     standalone layout - files copied across"
fi

# ------------------------------------------------------------- start it
say ""
say "8/9  starting the panel"
asowner "NODE_ENV=production PORT=$PORT $PM2 start server.js --name cloud360-panel --update-env" >/dev/null 2>&1 \
  || NODE_ENV=production PORT=$PORT $PM2 start server.js --name cloud360-panel --update-env >/dev/null 2>&1 \
  || say "     REPORT BACK - could not start it."
$PM2 save >/dev/null 2>&1
sleep 8
say "     $($PM2 list 2>/dev/null | grep -c 'cloud360-panel') copy running (there should be exactly 1)"

# ------------------------------------------------------------- prove it
say ""
say "9/9  proving the browser gets what it asks for"
BASE="http://127.0.0.1:$PORT"
HOME_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 "$BASE/")
if [ "$HOME_CODE" != "200" ] && [ "$HOME_CODE" != "307" ] && [ "$HOME_CODE" != "302" ]; then
  say "     the panel answered $HOME_CODE on its own address. Its log says:"
  L=$(ls -1t "/home/$OWNER/.pm2/logs/"*cloud360-panel-error*.log /root/.pm2/logs/*cloud360-panel-error*.log 2>/dev/null | head -1)
  [ -n "$L" ] && tail -n 20 "$L" | quote
  say ""
  say "REPORT BACK - send me the log in $WORK"
  exit 1
fi

HTML=$(curl -sL --max-time 25 "$BASE/")
OK=0; BAD=0
for u in $(echo "$HTML" | grep -oE '(src|href)="/_next/[^"]+"' | cut -d'"' -f2 | sort -u); do
  CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 "$BASE$u")
  if [ "$CODE" = "200" ]; then OK=$((OK+1)); else BAD=$((BAD+1)); say "     STILL BROKEN  $CODE  $u"; fi
done
say "     $OK file(s) served correctly, $BAD still failing"
[ "$OK" -eq 0 ] && warn "the page did not ask for any files - it may still be serving a cached copy"

# The sign-in screen is part of the main page - there is no /login address,
# so asking for one proves nothing. What proves the new code is running is
# that the API refuses an anonymous caller, and that the Email Validator
# address exists at all.
VMS=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$BASE/api/vms")
say "     /api/vms without signing in answers $VMS  (401 is what we want)"
case "$VMS" in
  401|403|302|307) : ;;
  200) warn "/api/vms still answers 200 without a login - your VM list is public, the security fix is not running" ;;
  *)   warn "/api/vms answers $VMS, which is neither locked nor working" ;;
esac

EV=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$BASE/api/email-validator")
say "     Email Validator answers $EV  (404 would mean it is not deployed)"
[ "$EV" = "404" ] && warn "the Email Validator is not in the running build"

LOGIN=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$BASE/")
say "     the panel's own page answers $LOGIN"
[ "$LOGIN" = "200" ] || warn "the panel's main page answers $LOGIN"

# ------------------------------------------------------------- summary
say ""
say "-------------------- COPY FROM HERE --------------------"
if [ "$BAD" -eq 0 ] && [ "$OK" -gt 0 ] && [ "$LOGIN" = "200" ] && [ -z "$WARN" ]; then
  say "FIXED. $OK files served, login is live, the VM list is no longer public."
  say "Open the panel and sign in. It asks once now, not on every refresh."
  say "Email Validator is in the left menu, under Golden Backups."
else
  say "PARTLY FIXED - $OK files served, $BAD failing."
  [ -n "$WARN" ] && { say "Still wrong:"; echo "$WARN" | sed '/^$/d' | tee -a "$REPORT"; }
  say "Send me the log in $WORK"
fi
say "--------------------- TO HERE --------------------------"
