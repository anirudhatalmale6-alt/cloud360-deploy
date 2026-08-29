#!/usr/bin/env bash
#
# Put the current ClarityAI code live on VM 138.
#
#   bash deploy-clarityai.sh
#
# The first version of this script assumed the site was at /var/www/clarityai/site
# and it is not. It now asks the machine where the site is, starting with the
# process manager that is actually running it, and only guesses afterwards.
#
# git never gets to sit at a password prompt - GIT_TERMINAL_PROMPT is off, so a
# credential problem fails in a second with an explanation instead of hanging.
#
# The build runs before anything is restarted, so a broken build leaves the site
# that is serving right now completely untouched.
#
set -uo pipefail

PM2_NAME="${CLARITYAI_PM2:-clarityai}"
PUBLIC="${CLARITYAI_URL:-https://clarityai.cloud360.ca}"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32mOK\033[0m   %s\n' "$*"; }
bad()  { printf '    \033[31mFAIL\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }

pm2cmd() { command -v pm2 >/dev/null 2>&1 && pm2 "$@" 2>/dev/null || sudo -u ubuntu24 pm2 "$@" 2>/dev/null; }

# ---------------------------------------------------------------------------
# 1. Where does this site actually live?
# ---------------------------------------------------------------------------
say "Finding the site on this machine"
SITE="${CLARITYAI_DIR:-}"

# Best answer: ask the process manager where the running app was started from.
if [ -z "$SITE" ]; then
  CWD=$(pm2cmd jlist | tr ',' '\n' | grep -o '"pm_cwd":"[^"]*"' | head -1 | cut -d'"' -f4)
  [ -n "$CWD" ] && [ -f "$CWD/package.json" ] && SITE="$CWD"
  [ -n "$SITE" ] && note "pm2 says the running app was started from here"
fi

# Then the places it has been before.
if [ -z "$SITE" ]; then
  for d in /var/www/clarityai/site /var/www/clarityai /var/www/clarity-ai \
           /home/ubuntu24/clarityai /home/ubuntu24/ClarityAI /opt/clarityai; do
    [ -f "$d/package.json" ] && { SITE="$d"; break; }
  done
fi

# Then look for it properly.
if [ -z "$SITE" ]; then
  CAND=$(sudo find /var/www /home /opt /srv -maxdepth 5 -name "next.config.mjs" -not -path "*/node_modules/*" 2>/dev/null | head -1)
  [ -n "$CAND" ] && SITE=$(dirname "$CAND")
fi

if [ -z "$SITE" ] || [ ! -f "$SITE/package.json" ]; then
  bad "Could not find the ClarityAI site on this machine."
  note "Send me the output of these two, and I will point the script straight at it:"
  note "    ls /var/www"
  note "    pm2 list"
  exit 1
fi
ok "Found it at $SITE"
cd "$SITE" || exit 1

# ---------------------------------------------------------------------------
# 2. Fetch the new code, without ever hanging on a password.
# ---------------------------------------------------------------------------
say "Where the site is now"
BEFORE=$(sudo git -C "$SITE" rev-parse --short HEAD 2>/dev/null)
note "commit ${BEFORE:-not a git checkout}"

say "Fetching the new code"
if [ -z "$BEFORE" ]; then
  bad "$SITE is not a git checkout, so there is nothing to pull."
  note "Tell me and I will send you a different way to get the files across."
  exit 1
fi

# sudo VAR=x cmd would make sudo hunt for a command named "VAR=x". It has to be
# env, or the prompt suppression quietly does not happen.
#
# fetch then fast-forward, not pull. A plain pull on a drifted checkout stops
# with "Need to specify how to reconcile divergent branches" and waits - a
# different fault that looks identical from the outside.
BRANCH=$(sudo git -C "$SITE" rev-parse --abbrev-ref HEAD 2>/dev/null)
PULL=$(sudo env GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true \
         git -C "$SITE" fetch origin "$BRANCH" 2>&1) && \
PULL="$PULL"$'\n'$(sudo git -C "$SITE" merge --ff-only FETCH_HEAD 2>&1)
RC=$?
echo "$PULL" | sed -E 's#https://[^@/]*@#https://#g; s/gh[pous]_[A-Za-z0-9_]*/***/g' | sed 's/^/    /'
if [ $RC -ne 0 ]; then
  bad "git could not fetch the code."
  case "$PULL" in
    *[Aa]uthentication*|*"could not read Username"*|*"Invalid username"*|*"terminal prompts disabled"*|*403*)
      note "The access token baked into this checkout's remote address is no longer"
      note "accepted by GitHub. That is the whole problem - nothing else is wrong." ;;
    *"Not possible to fast-forward"*|*"divergent"*|*"local changes"*|*"would be overwritten"*)
      note "This checkout has drifted from GitHub, so it cannot fast-forward cleanly." ;;
    *)
      note "See git's own words above." ;;
  esac
  note "Nothing has been changed and the site is still running exactly as it was."
  note "Send me this output and I will sort it out."
  exit 1
fi
AFTER=$(sudo git -C "$SITE" rev-parse --short HEAD 2>/dev/null)
[ "$BEFORE" = "$AFTER" ] && note "already up to date at $AFTER" || ok "now at $AFTER"

# ---------------------------------------------------------------------------
# 3. Build. Nothing is restarted unless this succeeds.
# ---------------------------------------------------------------------------
say "Building"
BUILD=$(sudo npm run build 2>&1)
RC=$?
echo "$BUILD" | tail -25 | sed 's/^/    /'
if [ $RC -ne 0 ]; then
  bad "The build failed. Nothing has been restarted - the site running right now is untouched."
  note "Send me the lines above."
  exit 1
fi
ok "Built"

say "Restarting"
pm2cmd restart "$PM2_NAME" >/dev/null
sleep 4
LOCAL=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 http://127.0.0.1:3000/ 2>/dev/null)
if [ "$LOCAL" = "200" ]; then ok "the app is answering on this machine"; else bad "the app answered $LOCAL locally"; fi

# ---------------------------------------------------------------------------
# 4. Prove it, the way a visitor sees it.
# ---------------------------------------------------------------------------
say "Checking the pages a visitor sees"
FAILED=0
for path in "/" "/book" "/privacy" "/terms" "/quiz" "/clarityai-safety-guide.pdf"; do
  CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 "$PUBLIC$path" 2>/dev/null)
  if [ "$CODE" = "200" ]; then ok "$path"; else bad "$path answered $CODE"; FAILED=1; fi
done

say "Checking that no button still goes nowhere"
DEAD=$(curl -s --max-time 25 "$PUBLIC/" 2>/dev/null | grep -o 'href="#"' | wc -l | tr -d ' ')
if [ "$DEAD" = "0" ]; then ok "none left"; else bad "$DEAD links on the home page still go nowhere"; FAILED=1; fi

say "Done"
[ "$FAILED" = "0" ] && note "Everything above passed." || note "Send me this output - something above did not pass."
exit $FAILED
