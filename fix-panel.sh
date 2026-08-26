#!/bin/sh
# Cloud360 panel - the page loads but stays blank.
#
# Every stylesheet and script the page asks for is coming back as
# "Internal Server Error", so the browser gets an empty shell and nothing to
# draw with. This script says WHY first, then repairs it, then proves the
# repair worked before it finishes.
#
# It checks there is room to work before it changes anything.
# Safe to run more than once.

REPORT=/tmp/panel-report.txt
: > "$REPORT"

say()  { echo "$@"; echo "$@" >> "$REPORT"; }
hide() { sed -E 's/gh[pous]_[A-Za-z0-9_]*/HIDDEN/g'; }
quote(){ hide | sed 's/^/     | /' | tee -a "$REPORT"; }

say "==== Cloud360 panel repair - $(date) ===="
say ""

# ---------------------------------------------------------------- find it
say "1/7  finding the panel folder ..."
DIR=""
for base in /opt /root /home /srv /var/www /usr/local; do
  [ -d "$base" ] || continue
  F=$(find "$base" -maxdepth 5 -name 'next.config.mjs' -not -path '*/node_modules/*' 2>/dev/null | head -1)
  if [ -n "$F" ] && [ -f "$(dirname "$F")/server.js" ]; then DIR=$(dirname "$F"); break; fi
done
if [ -z "$DIR" ]; then
  say "REPORT BACK - could not find the panel folder automatically."
  exit 1
fi
OWNER=$(stat -c %U "$DIR")
GROUP=$(stat -c %G "$DIR")
say "     found $DIR   (owned by $OWNER)"
cd "$DIR" || exit 1

asowner() { runuser -l "$OWNER" -c "cd '$DIR' && $1"; }

# ------------------------------------------------------------- what is wrong
say ""
say "2/7  what the box looks like right now"
say "     disk free   $(df -Ph . | awk 'NR==2{print $4" of "$2" ("$5" used)"}')"
say "     memory      $(free -m | awk '/^Mem/{print $7" MB available of "$2" MB"}')"
say "     swap        $(free -m | awk '/^Swap/{print $2" MB"}')"
say "     node        $(asowner 'node -v' 2>/dev/null || echo unknown)"
say "     commit      $(git rev-parse --short HEAD 2>/dev/null || echo 'not a git checkout')"

say ""
say "3/7  the built files the browser is asking for"
if [ -d .next ]; then
  say "     .next          $(stat -c '%U:%G %a' .next)"
else
  say "     .next          MISSING"
fi
if [ -d .next/static ]; then
  say "     .next/static   $(stat -c '%U:%G %a' .next/static), $(find .next/static -type f 2>/dev/null | wc -l) files"
  CH=$(find .next/static -name 'webpack-*.js' 2>/dev/null | head -1)
  if [ -n "$CH" ]; then
    say "     sample chunk   $CH"
    say "                    $(stat -c '%U:%G %a  %s bytes' "$CH")"
    [ -L "$CH" ] && say "                    IS A SYMLINK -> $(readlink "$CH")"
  else
    say "     sample chunk   none found under .next/static"
  fi
else
  say "     .next/static   MISSING  <-- this alone explains a blank page"
fi
[ -d .next/standalone ] && say "     .next/standalone exists - the server may be serving from there instead"

say ""
say "4/7  what the panel process itself logged"
LOGS=$(ls -1t "/home/$OWNER/.pm2/logs/"*error*.log /root/.pm2/logs/*error*.log 2>/dev/null | head -1)
if [ -n "$LOGS" ] && [ -f "$LOGS" ]; then
  say "     from $LOGS"
  tail -n 25 "$LOGS" | quote
else
  say "     no pm2 error log found - skipping"
fi

# ------------------------------------------------------------------ repair
say ""
say "5/7  rebuilding"
FREE_KB=$(df -Pk . | awk 'NR==2{print $4}')
if [ "$FREE_KB" -lt 2097152 ]; then
  say ""
  say "REPORT BACK - only $((FREE_KB/1024)) MB free. A rebuild needs about 2 GB."
  say "Nothing was changed. Send me /tmp/panel-report.txt and I will clear space first."
  exit 1
fi

if [ -d .git ] && [ -n "$(git remote 2>/dev/null)" ]; then
  git config --global --add safe.directory "$DIR" >/dev/null 2>&1
  BEFORE=$(git rev-parse --short HEAD 2>/dev/null)
  if asowner 'git pull --ff-only' > /tmp/panel-pull.log 2>&1; then
    say "     code $BEFORE -> $(git rev-parse --short HEAD)"
  else
    say "     could not update the code, rebuilding what is already here. Reason:"
    tail -n 5 /tmp/panel-pull.log | quote
  fi
fi

# A Next build wants more heap than the default on a small box. Give it what
# the machine actually has, rather than letting it die half way and leave
# behind the half-built folder that produces exactly this blank page.
MEM_MB=$(free -m | awk '/^Mem/{print $2}')
HEAP=$((MEM_MB * 3 / 4))
[ "$HEAP" -lt 1024 ] && HEAP=1024
[ "$HEAP" -gt 4096 ] && HEAP=4096
say "     building with a ${HEAP} MB heap limit ..."

BUILD="NODE_OPTIONS=--max-old-space-size=$HEAP npx --yes next build"
if asowner "$BUILD" > /tmp/panel-build.log 2>&1; then
  say "     build OK"
else
  say "     first attempt failed, installing dependencies and trying once more ..."
  asowner 'npm install --no-audit --no-fund' >> /tmp/panel-build.log 2>&1
  if asowner "$BUILD" >> /tmp/panel-build.log 2>&1; then
    say "     build OK on the second attempt"
  else
    say ""
    say "REPORT BACK - the rebuild failed. Last lines were:"
    tail -n 25 /tmp/panel-build.log | quote
    say ""
    say "Send me /tmp/panel-report.txt"
    exit 1
  fi
fi

# A build run as root leaves files the panel's own user cannot read, which is
# itself a way to produce this same blank page. Put the ownership back.
chown -R "$OWNER":"$GROUP" .next 2>/dev/null
find .next -type d -exec chmod 755 {} + 2>/dev/null
find .next -type f -exec chmod 644 {} + 2>/dev/null

# Standalone builds keep the server in .next/standalone and do NOT copy the
# static files across. If that layout is in use, copy them.
if [ -d .next/standalone ]; then
  mkdir -p .next/standalone/.next
  cp -r .next/static .next/standalone/.next/ 2>/dev/null
  [ -d public ] && cp -r public .next/standalone/ 2>/dev/null
  chown -R "$OWNER":"$GROUP" .next/standalone 2>/dev/null
  say "     standalone layout - static files copied across"
fi

say ""
say "6/7  restarting the panel"
asowner 'npx --yes pm2 restart cloud360-panel --update-env' >/dev/null 2>&1 \
  || asowner 'npx --yes pm2 start server.js --name cloud360-panel' >/dev/null 2>&1 \
  || npx --yes pm2 restart cloud360-panel >/dev/null 2>&1 \
  || say "     REPORT BACK - could not restart it automatically."
sleep 6

# ------------------------------------------------------------------ prove it
say ""
say "7/7  checking the browser will actually get its files now"
PORT=""
for p in 3000 3001 8080 8000; do
  curl -s -o /dev/null --max-time 5 "http://127.0.0.1:$p/" && { PORT=$p; break; }
done
if [ -z "$PORT" ]; then
  say "     REPORT BACK - the panel is not answering on this box at all."
  say "     Send me /tmp/panel-report.txt"
  exit 1
fi
BASE="http://127.0.0.1:$PORT"
say "     panel answering on port $PORT"

HTML=$(curl -s --max-time 20 "$BASE/")
OK=0; BAD=0
for u in $(echo "$HTML" | grep -oE '(src|href)="/_next/[^"]+"' | cut -d'"' -f2 | sort -u); do
  CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$BASE$u")
  if [ "$CODE" = "200" ]; then
    OK=$((OK+1))
  else
    BAD=$((BAD+1)); say "     STILL BROKEN  $CODE  $u"
  fi
done
say "     $OK file(s) served correctly, $BAD still failing"

say ""
if [ "$BAD" -eq 0 ] && [ "$OK" -gt 0 ]; then
  say "FIXED. Open the panel and sign in. It asks for the password once now"
  say "instead of on every refresh."
  say "Email Validator is in the left menu, under Golden Backups."
else
  say "REPORT BACK - still broken. Send me /tmp/panel-report.txt"
fi
say ""
say "(a copy of everything above is saved at /tmp/panel-report.txt)"
