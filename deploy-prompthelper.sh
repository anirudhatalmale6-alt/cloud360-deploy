#!/usr/bin/env bash
#
# Put the current Prompt Helper site live on VM 135.
#
#   bash deploy-prompthelper.sh
#
# It tries git first. The checkout on that machine has an old access token
# baked into its remote address which GitHub no longer accepts, so git sits
# there asking for a password that nobody can type. This script never lets that
# happen - GIT_TERMINAL_PROMPT is off, so git fails in a second instead of
# hanging - and then falls back to downloading the site directly.
#
# The fallback is safe. Prompt Helper is a public website; every file in that
# download is already served to anyone who visits it.
#
# The current files are copied to a dated backup before anything is written, so
# this is reversible.
#
set -uo pipefail

PAYLOAD="https://raw.githubusercontent.com/anirudhatalmale6-alt/cloud360-deploy/main/payloads/prompthelper-site.tar.gz"
PUBLIC="${PROMPTHELPER_URL:-https://aiprompthelper.cloud360.ca}"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32mOK\033[0m   %s\n' "$*"; }
bad()  { printf '    \033[31mFAIL\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. Find the site. Do not assume a path - the ClarityAI script assumed one and
#    was simply wrong about it.
# ---------------------------------------------------------------------------
say "Finding the site on this machine"
SITE=""
for d in /var/www/prompt-helper /var/www/prompthelper /var/www/html /home/ubuntu24/prompt-helper; do
  [ -f "$d/index.html" ] && { SITE="$d"; break; }
done
if [ -z "$SITE" ]; then
  SITE=$(sudo find /var/www /home /opt /srv -maxdepth 4 -name "index.html" -path "*prompt*" 2>/dev/null | head -1)
  SITE="${SITE%/index.html}"
fi
if [ -z "$SITE" ] || [ ! -d "$SITE" ]; then
  bad "Could not find the Prompt Helper files on this machine."
  note "Send me the output of:   ls /var/www"
  exit 1
fi
ok "Found it at $SITE"
cd "$SITE" || exit 1

# ---------------------------------------------------------------------------
# 2. Back up first.
# ---------------------------------------------------------------------------
BK="/home/ubuntu24/prompt-helper-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
sudo tar czf "$BK" -C "$SITE" . 2>/dev/null && ok "Current site backed up to $BK" \
  || note "could not write a backup - carrying on, the files are all in git anyway"

# ---------------------------------------------------------------------------
# 3. Try git. One second, no prompt.
# ---------------------------------------------------------------------------
say "Trying git first"
USED_GIT=no
if sudo test -d "$SITE/.git"; then
  BEFORE=$(sudo git -C "$SITE" rev-parse --short HEAD 2>/dev/null)
  BRANCH=$(sudo git -C "$SITE" rev-parse --abbrev-ref HEAD 2>/dev/null)
  note "on branch $BRANCH at $BEFORE"
  # `sudo VAR=x cmd` is not a thing - sudo would look for a command called
  # "VAR=x". It has to go through env, or the prompt-suppression silently does
  # not happen and we are back to a hung terminal.
  #
  # fetch then fast-forward, rather than pull. A plain pull on a checkout that
  # has drifted stops with "Need to specify how to reconcile divergent
  # branches" and waits, which is a different failure that looks like the same
  # one. Fast-forward or nothing.
  PULL=$(sudo env GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true \
           git -C "$SITE" fetch origin "$BRANCH" 2>&1) && \
  PULL="$PULL"$'\n'$(sudo git -C "$SITE" merge --ff-only FETCH_HEAD 2>&1)
  RC=$?
  # Strip anything that looks like a credential out of git's chatter before it
  # reaches the screen.
  echo "$PULL" | sed -E 's#https://[^@/]*@#https://#g; s/gh[pous]_[A-Za-z0-9_]*/***/g' | sed 's/^/    /'
  if [ $RC -eq 0 ]; then
    USED_GIT=yes
    ok "pulled, now at $(sudo git -C "$SITE" rev-parse --short HEAD)"
  else
    # Say what actually went wrong. Announcing "authentication" for what was
    # really a divergent branch sends the next hour in the wrong direction.
    case "$PULL" in
      *[Aa]uthentication*|*"could not read Username"*|*"Invalid username"*|*"terminal prompts disabled"*|*403*)
        note "git could not authenticate - the token in this checkout's remote is no longer"
        note "accepted by GitHub." ;;
      *"Not possible to fast-forward"*|*"divergent"*|*"local changes"*|*"would be overwritten"*)
        note "this checkout has drifted from GitHub, so a clean fast-forward is not possible." ;;
      *)
        note "git did not succeed - see its own words above." ;;
    esac
    note "Falling back to a direct download instead, which does not need git at all."
  fi
else
  note "this is not a git checkout - using the direct download"
fi

# ---------------------------------------------------------------------------
# 4. Fallback: fetch the site and unpack it over the top.
# ---------------------------------------------------------------------------
if [ "$USED_GIT" = no ]; then
  say "Downloading the site"
  TMP=$(mktemp -d)
  if ! curl -sSL --max-time 120 "$PAYLOAD" -o "$TMP/site.tar.gz"; then
    bad "Could not download the site files."
    rm -rf "$TMP"; exit 1
  fi
  SIZE=$(wc -c < "$TMP/site.tar.gz" | tr -d ' ')
  if [ "$SIZE" -lt 20000 ]; then
    bad "The download came back too small ($SIZE bytes) - something is wrong with it."
    note "Nothing has been changed."
    rm -rf "$TMP"; exit 1
  fi
  if ! tar tzf "$TMP/site.tar.gz" >/dev/null 2>&1; then
    bad "The download is not a readable archive. Nothing has been changed."
    rm -rf "$TMP"; exit 1
  fi
  ok "Downloaded and checked ($SIZE bytes)"

  sudo tar xzf "$TMP/site.tar.gz" -C "$SITE"
  rm -rf "$TMP"
  ok "Unpacked into $SITE"

  # nginx must be able to read what we just wrote. Readability only - changing
  # the owner would break the git checkout for whenever the token is fixed.
  sudo chmod -R a+rX "$SITE"
fi

# ---------------------------------------------------------------------------
# 5. Prove it, the way a visitor sees it.
# ---------------------------------------------------------------------------
say "Checking the pages a visitor sees"
FAILED=0
for path in "/" "/about.html" "/contact.html" "/privacy.html" "/terms.html" "/blog/"; do
  CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 "$PUBLIC$path" 2>/dev/null)
  if [ "$CODE" = "200" ]; then ok "$path"; else bad "$path answered $CODE"; FAILED=1; fi
done

say "Checking that no link still goes nowhere"
HOME_HTML=$(curl -s --max-time 25 "$PUBLIC/" 2>/dev/null)
DEAD=$(printf '%s' "$HOME_HTML" | grep -o 'href="#"' | wc -l | tr -d ' ')
if [ "$DEAD" = "0" ]; then ok "none left on the home page"; else bad "$DEAD links still go nowhere"; FAILED=1; fi

say "Checking the email box really posts now"
if printf '%s' "$HOME_HTML" | grep -q "/signup"; then
  ok "it posts to the sign-up endpoint"
else
  bad "the old handler that sent nothing is still there - the new files did not take"
  FAILED=1
fi

say "Done"
if [ "$FAILED" = "0" ]; then
  note "Everything above passed."
else
  note "Send me this output. To undo, run:"
  note "    sudo tar xzf $BK -C $SITE"
fi
exit $FAILED
