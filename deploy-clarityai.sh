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
#   bash deploy-clarityai.sh --set-token
#
# ...if git says the token is no longer accepted. That asks for a fresh GitHub
# token, reads it invisibly, and writes it into the checkout's remote address.
# It is never echoed, never logged, and never appears in the process list.
#
set -uo pipefail

PM2_NAME="${CLARITYAI_PM2:-clarityai}"

# clarityai.ca is the real address now, not just the cloud360 one. Check both -
# they are served by the same app through the same proxy, so if they disagree
# the fault is in the proxy and it is worth knowing before anyone celebrates.
PUBLIC="${CLARITYAI_URL:-https://clarityai.ca}"
ALSO="${CLARITYAI_URL_ALT:-https://clarityai.cloud360.ca}"

# Optional. A short string that must appear in the served HTML for the deploy to
# count as done. Without it this script can only prove that something is up, not
# that YOUR change is the thing being served - which is a different question and
# the one that usually goes wrong.
#
#   EXPECT="could not save your email" bash deploy-clarityai.sh
#
EXPECT="${EXPECT:-}"
EXPECT_PATH="${EXPECT_PATH:-/quiz}"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32mOK\033[0m   %s\n' "$*"; }
bad()  { printf '    \033[31mFAIL\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }

pm2cmd() { command -v pm2 >/dev/null 2>&1 && pm2 "$@" 2>/dev/null || sudo -u ubuntu24 pm2 "$@" 2>/dev/null; }

# Anything printed by this script goes through here. A remote address with a
# token in it is one careless echo away from ending up in a chat window.
scrub() { sed -E 's#https://[^@/]*@#https://#g; s/gh[pous]_[A-Za-z0-9_]{6,}/***/g'; }

# ---------------------------------------------------------------------------
# Run git against the checkout, without sudo if that works.
#
# The old version put sudo in front of every git call. That is worse than it
# looks. When the checkout belongs to ubuntu24 and git runs as root, git refuses
# with "detected dubious ownership" - and the script read that failure as "this
# is not a git checkout", which is a different fault with a different fix and
# sent the whole diagnosis down the wrong road.
#
# Try as the current user first, because that is usually who owns it, and only
# reach for sudo if that genuinely cannot see the repository.
# ---------------------------------------------------------------------------
GIT_PREFIX=""
git_at() {
  if [ -z "$GIT_PREFIX" ]; then
    git -C "$SITE" "$@" 2>&1
  else
    sudo env GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true git -C "$SITE" "$@" 2>&1
  fi
}
choose_git() {
  if git -C "$SITE" rev-parse --git-dir >/dev/null 2>&1; then
    GIT_PREFIX=""; return 0
  fi
  if sudo -n git -C "$SITE" rev-parse --git-dir >/dev/null 2>&1; then
    GIT_PREFIX="sudo"; note "using sudo for git - the checkout is not owned by $(id -un)"; return 0
  fi
  # Neither worked. Say which of the two possible reasons it is, rather than
  # asserting the checkout does not exist.
  if [ -d "$SITE/.git" ]; then
    bad "$SITE has a .git directory but git will not read it."
    WHY=$(git -C "$SITE" rev-parse --git-dir 2>&1 | head -2)
    printf '%s\n' "$WHY" | scrub | sed 's/^/    /'
    case "$WHY" in
      *"dubious ownership"*)
        note "git is refusing because the checkout belongs to someone else."
        note "Whoever owns it should run this script, or mark it safe with"
        note "    git config --global --add safe.directory $SITE" ;;
      *) note "Send me the two lines above." ;;
    esac
  else
    bad "$SITE is not a git checkout, so there is nothing to pull."
    note "Tell me and I will send you a different way to get the files across."
  fi
  note "Nothing has been changed and the site is still running exactly as it was."
  exit 1
}

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
# 1b. --set-token, for when the baked-in token has expired.
#
# The checkout's remote address carries a GitHub token, and tokens expire. When
# that happens git says "Invalid username or token" and the deploy stops dead.
#
# The token is read with the terminal echo off, so it is not visible on screen,
# not in the shell history, and not in the process list. It goes straight into
# the remote address and nowhere else.
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--set-token" ]; then
  say "Setting a fresh GitHub token on this checkout"
  choose_git
  URL=$(git_at remote get-url origin)
  BARE=$(printf '%s' "$URL" | sed -E 's#https://[^@/]*@#https://#')
  note "remote is $(printf '%s' "$BARE")"
  note ""
  note "Paste the token and press enter. Nothing will appear as you type."
  printf '    token > '
  stty -echo 2>/dev/null; read -r TOKEN; stty echo 2>/dev/null; printf '\n'

  if [ -z "$TOKEN" ]; then
    bad "Nothing was entered. The remote address has not been changed."
    exit 1
  fi

  NEWURL=$(printf '%s' "$BARE" | sed -E "s#https://#https://x-access-token:$TOKEN@#")
  git_at remote set-url origin "$NEWURL" >/dev/null
  TOKEN=""

  # Prove it before declaring victory. A token that is set but not accepted is
  # exactly the state we were already in.
  if GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true \
       git_at ls-remote origin HEAD >/dev/null 2>&1; then
    ok "GitHub accepted it. Run the script again without --set-token to deploy."
    exit 0
  fi
  bad "GitHub still refused it."
  note "The token needs read access to the ClarityAI repository. If it is a"
  note "fine-grained token, that repository has to be selected in its list."
  note "Nothing else has been changed."
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. Fetch the new code, without ever hanging on a password.
# ---------------------------------------------------------------------------
say "Where the site is now"
choose_git
BEFORE=$(git_at rev-parse --short HEAD)
note "commit $BEFORE"

say "Fetching the new code"

# sudo VAR=x cmd would make sudo hunt for a command named "VAR=x". It has to be
# env, or the prompt suppression quietly does not happen.
#
# fetch then fast-forward, not pull. A plain pull on a drifted checkout stops
# with "Need to specify how to reconcile divergent branches" and waits - a
# different fault that looks identical from the outside.
BRANCH=$(git_at rev-parse --abbrev-ref HEAD)
PULL=$(GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true git_at fetch origin "$BRANCH") && \
PULL="$PULL"$'\n'$(git_at merge --ff-only FETCH_HEAD)
RC=$?
echo "$PULL" | scrub | sed 's/^/    /'
if [ $RC -ne 0 ]; then
  bad "git could not fetch the code."
  case "$PULL" in
    *[Aa]uthentication*|*"could not read Username"*|*"Invalid username"*|*"terminal prompts disabled"*|*403*|*"Repository not found"*)
      note "The access token baked into this checkout's remote address is no longer"
      note "accepted by GitHub. That is the whole problem - nothing else is wrong."
      note ""
      note "The repository is private, so it cannot be fetched without one. Make a"
      note "new token on your GitHub account with read access to ClarityAI, then"
      note "run this same script with  --set-token  on the end and paste it in."
      note "It is read invisibly and goes nowhere except this checkout's config."
      note "Do not paste it into our chat - I do not need to see it."
      exit 1 ;;
    *"Not possible to fast-forward"*|*"divergent"*|*"local changes"*|*"would be overwritten"*)
      note "This checkout has drifted from GitHub, so it cannot fast-forward cleanly." ;;
    *)
      note "See git's own words above." ;;
  esac
  note "Nothing has been changed and the site is still running exactly as it was."
  note "Send me this output and I will sort it out."
  exit 1
fi
AFTER=$(git_at rev-parse --short HEAD)
[ "$BEFORE" = "$AFTER" ] && note "already up to date at $AFTER" || ok "now at $AFTER"

# ---------------------------------------------------------------------------
# 3. Build. Nothing is restarted unless this succeeds.
# ---------------------------------------------------------------------------
say "Building"
# Build as whoever owns the checkout, not as root. A root-owned .next directory
# is a slow, confusing failure later - the app runs as ubuntu24 and cannot write
# its own cache, and the symptom shows up nowhere near this script.
OWNER=$(stat -c '%U' "$SITE" 2>/dev/null)
if [ "$OWNER" = "$(id -un)" ] || [ -z "$OWNER" ]; then
  BUILD=$(cd "$SITE" && npm run build 2>&1)
else
  note "building as $OWNER, who owns the checkout"
  BUILD=$(sudo -u "$OWNER" sh -c "cd '$SITE' && npm run build" 2>&1)
fi
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
# Ask pm2 which port it started the app on rather than assuming 3000. A fixed
# port is a good way to get a confident OK from somebody else's server.
APP_PORT=$(pm2cmd jlist | tr ',' '\n' | grep -o '"PORT"[^,}]*' | head -1 | grep -oE '[0-9]+' | head -1)
APP_PORT=${APP_PORT:-3000}
LOCALBODY=$(curl -s --max-time 20 "http://127.0.0.1:$APP_PORT/" 2>/dev/null)
LOCAL=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "http://127.0.0.1:$APP_PORT/" 2>/dev/null)
if [ "$LOCAL" != "200" ]; then
  bad "the app answered $LOCAL on port $APP_PORT"
elif printf '%s' "$LOCALBODY" | grep -qi 'clarity'; then
  ok "the app is answering on this machine, on port $APP_PORT, and it is ClarityAI"
else
  # A 200 from the right port is not the same as a 200 from the right app.
  bad "something answers on port $APP_PORT but it is not ClarityAI"
  note "Whatever is on that port is not this site. Send me this output."
fi

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

# ---------------------------------------------------------------------------
# 5. The two questions this script used to skip.
# ---------------------------------------------------------------------------
say "Checking the other address serves the same thing"
# If clarityai.ca and clarityai.cloud360.ca disagree, one of them is being
# served by something else and a deploy will look fine on whichever one you
# happened to check.
T1=$(curl -sk --max-time 25 "$PUBLIC/"  2>/dev/null | tr -d '\n' | sed -n 's/.*<title[^>]*>\([^<]*\)<\/title>.*/\1/p' | head -1)
T2=$(curl -sk --max-time 25 "$ALSO/"    2>/dev/null | tr -d '\n' | sed -n 's/.*<title[^>]*>\([^<]*\)<\/title>.*/\1/p' | head -1)
note "$PUBLIC shows  ${T1:-(nothing)}"
note "$ALSO shows  ${T2:-(nothing)}"
case "$T1" in
  "Welcome to nginx!"|"Welcome to nginx")
    bad "$PUBLIC is serving the nginx default page, not the site."
    note "The machine behind the proxy does not recognise that name. Send me this."
    FAILED=1 ;;
  "$T2") ok "both addresses serve the same site" ;;
  *)     bad "the two addresses are serving different pages"; FAILED=1 ;;
esac

if [ -n "$EXPECT" ]; then
  say "Checking the change is actually the thing being served"
  # Moving the checkout forward and rebuilding proves neither of these on its
  # own. The build can succeed while the old process keeps serving, or the
  # process can be restarted from a directory that is not this one. The only
  # answer that settles it is to ask the public address for the page and look
  # for something that only exists in the new code.
  # Look in the page AND in the javascript it loads. Most of this site's text
  # lives inside client components, so it is compiled into a chunk rather than
  # printed into the initial HTML - grepping the HTML alone reports a correct
  # deploy as a failure. That is worse than no check, because it sends everyone
  # hunting for a fault that is not there.
  HTML=$(curl -sk --max-time 25 "$PUBLIC$EXPECT_PATH" 2>/dev/null)
  FOUND=no
  printf '%s' "$HTML" | grep -qF "$EXPECT" && FOUND=yes && WHERE="the page itself"
  if [ "$FOUND" = no ]; then
    for chunk in $(printf '%s' "$HTML" | grep -oE '/_next/static/[^"]+\.js' | sort -u); do
      if curl -sk --max-time 25 "$PUBLIC$chunk" 2>/dev/null | grep -qF "$EXPECT"; then
        FOUND=yes; WHERE="$chunk"; break
      fi
    done
  fi
  if [ "$FOUND" = yes ]; then
    ok "found it in $WHERE - the new code is live"
  else
    bad "$EXPECT_PATH does not contain the expected change yet"
    note "The checkout moved to $AFTER and the build succeeded, so the code is"
    note "on the machine. What is being served did not come from it. That is"
    note "usually a second copy of the app still running, or pm2 restarting a"
    note "different directory than the one this script found at $SITE."
    note "Send me this output - do not tell anyone it is deployed."
    FAILED=1
  fi
fi

say "Done"
[ "$FAILED" = "0" ] && note "Everything above passed." || note "Send me this output - something above did not pass."
exit $FAILED
