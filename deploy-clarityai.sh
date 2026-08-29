#!/usr/bin/env bash
#
# Put the current ClarityAI code live on VM 138.
#
#   bash deploy-clarityai.sh
#
# Pulls, builds, restarts, and then checks the pages from outside. If the build
# fails it stops before restarting anything, so the site that is running now
# keeps running.
#
set -uo pipefail

SITE="${CLARITYAI_DIR:-/var/www/clarityai/site}"
PM2_NAME="${CLARITYAI_PM2:-clarityai}"
PUBLIC="${CLARITYAI_URL:-https://clarityai.cloud360.ca}"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32mOK\033[0m   %s\n' "$*"; }
bad()  { printf '    \033[31mFAIL\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }

[ -d "$SITE" ] || { bad "$SITE is not here - is this VM 138?"; exit 1; }
cd "$SITE" || exit 1

say "Where the site is now"
BEFORE=$(sudo git rev-parse --short HEAD 2>/dev/null)
note "commit $BEFORE"

say "Fetching the new code"
# The remote and its credentials are already set up in this checkout - nothing
# is typed in here and nothing is printed out.
PULL=$(sudo git pull 2>&1)
echo "$PULL" | sed -E 's#https://[^@]*@#https://#g' | sed 's/^/    /'
AFTER=$(sudo git rev-parse --short HEAD 2>/dev/null)
if [ "$BEFORE" = "$AFTER" ]; then
  note "already up to date at $AFTER - carrying on so the build is definitely current"
else
  ok "now at $AFTER"
fi

say "Building"
if ! sudo npm run build 2>&1 | tail -25 | sed 's/^/    /'; then
  bad "The build failed. Nothing has been restarted - the site running right now is untouched."
  note "Send me the lines above."
  exit 1
fi
ok "Built"

say "Restarting"
sudo pm2 restart "$PM2_NAME" >/dev/null 2>&1 || sudo -u ubuntu24 pm2 restart "$PM2_NAME" >/dev/null 2>&1
sleep 4
LOCAL=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 http://127.0.0.1:3000/ 2>/dev/null)
if [ "$LOCAL" = "200" ]; then ok "the app is answering on this machine"; else bad "the app answered $LOCAL locally"; fi

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
