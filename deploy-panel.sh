#!/bin/sh
# Cloud360 panel - pull the latest code, rebuild, restart.
# Finds the panel folder itself, changes nothing until it knows it can,
# and prints one line at the end saying what to report back.
#
# Safe to run more than once.

# Git's error messages go in a directory made fresh for this run. They used to
# go to fixed names in /tmp, where a leftover file from an earlier run - or one
# owned by another user - gets read back as if it belonged to this one.
WORK=$(mktemp -d /tmp/panel-deploy.XXXXXX) || {
  echo "Could not create a working directory under /tmp. Nothing has been changed."
  exit 1
}
trap 'rm -rf "$WORK"' EXIT

echo "1/5  finding the panel folder ..."
DIR=""
for base in /opt /root /home /srv /var/www /usr/local; do
  [ -d "$base" ] || continue
  F=$(find "$base" -maxdepth 5 -name 'next.config.mjs' -not -path '*/node_modules/*' 2>/dev/null | head -1)
  if [ -n "$F" ] && [ -f "$(dirname "$F")/server.js" ]; then DIR=$(dirname "$F"); break; fi
done

if [ -z "$DIR" ]; then
  echo ""
  echo "REPORT BACK - could not find the panel folder automatically."
  exit 1
fi
echo "     found $DIR"

cd "$DIR" || exit 1

if [ ! -d .git ]; then
  echo ""
  echo "REPORT BACK - $DIR is not a git checkout, so it cannot pull."
  exit 1
fi

echo "2/5  checking it can reach the code ..."
if [ -z "$(git remote)" ]; then
  echo ""
  echo "REPORT BACK - this checkout has no code repository configured, so it cannot update itself."
  exit 1
fi
BEFORE=$(git rev-parse --short HEAD 2>/dev/null)
if ! git fetch --quiet 2>$WORK/fetch-err; then
  echo ""
  echo "REPORT BACK - could not reach the code repository. The remotes on this box are:"
  git remote
  echo "and the error was:"
  sed -E 's/gh[pous]_[A-Za-z0-9_]*/HIDDEN/g' $WORK/fetch-err
  rm -f $WORK/fetch-err
  exit 1
fi
rm -f $WORK/fetch-err

echo "3/5  updating the code ..."
if ! git pull --ff-only 2>$WORK/pull-err; then
  echo ""
  echo "REPORT BACK - the update would not apply cleanly. Nothing was changed. The reason was:"
  sed -E 's/gh[pous]_[A-Za-z0-9_]*/HIDDEN/g' $WORK/pull-err
  rm -f $WORK/pull-err
  exit 1
fi
rm -f $WORK/pull-err
AFTER=$(git rev-parse --short HEAD 2>/dev/null)
echo "     $BEFORE -> $AFTER"

echo "4/5  rebuilding (this takes a minute) ..."
if ! npx --yes next build; then
  echo ""
  echo "REPORT BACK - the rebuild failed. The panel is still running on the old version."
  exit 1
fi

echo "5/5  restarting the panel ..."
npx --yes pm2 restart cloud360-panel || npx --yes pm2 start server.js --name cloud360-panel

echo ""
echo "Done. The panel is now on $AFTER."
echo "Open the panel and look for Email Validator in the left menu."
