#!/usr/bin/env bash
#
# Put the current Prompt Helper code live on VM 135.
#
#   bash deploy-prompthelper.sh
#
# It is a static site, so this is a pull and a check. Nothing is compiled and
# nothing is restarted.
#
set -uo pipefail

SITE="${PROMPTHELPER_DIR:-/var/www/prompt-helper}"
PUBLIC="${PROMPTHELPER_URL:-https://aiprompthelper.cloud360.ca}"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32mOK\033[0m   %s\n' "$*"; }
bad()  { printf '    \033[31mFAIL\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }

[ -d "$SITE" ] || { bad "$SITE is not here - is this VM 135?"; exit 1; }
cd "$SITE" || exit 1

say "Where the site is now"
BEFORE=$(sudo git rev-parse --short HEAD 2>/dev/null)
BRANCH=$(sudo git rev-parse --abbrev-ref HEAD 2>/dev/null)
note "commit $BEFORE on branch $BRANCH"

say "Fetching the new code"
# Both branches carry the same commit, so whichever this checkout follows is
# the right one. Any credentials in the remote URL are stripped from the output.
PULL=$(sudo git pull origin "$BRANCH" 2>&1)
echo "$PULL" | sed -E 's#https://[^@]*@#https://#g' | sed 's/^/    /'
AFTER=$(sudo git rev-parse --short HEAD 2>/dev/null)
[ "$BEFORE" = "$AFTER" ] && note "already up to date at $AFTER" || ok "now at $AFTER"

say "Checking the pages a visitor sees"
FAILED=0
for path in "/" "/about.html" "/contact.html" "/privacy.html" "/terms.html" "/blog/"; do
  CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 "$PUBLIC$path" 2>/dev/null)
  if [ "$CODE" = "200" ]; then ok "$path"; else bad "$path answered $CODE"; FAILED=1; fi
done

say "Checking that no link still goes nowhere"
DEAD=$(curl -s --max-time 25 "$PUBLIC/" 2>/dev/null | grep -o 'href="#"' | wc -l | tr -d ' ')
if [ "$DEAD" = "0" ]; then ok "none left on the home page"; else bad "$DEAD links still go nowhere"; FAILED=1; fi

say "Checking the email box really posts now"
if curl -s --max-time 25 "$PUBLIC/" 2>/dev/null | grep -q "/signup"; then
  ok "it posts to the sign-up endpoint"
else
  bad "the old handler that sent nothing is still there - the pull did not take"
  FAILED=1
fi

say "Done"
[ "$FAILED" = "0" ] && note "Everything above passed." || note "Send me this output - something above did not pass."
exit $FAILED
