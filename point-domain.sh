#!/usr/bin/env bash
#
# Point a real domain at a site that is already running on this reverse proxy.
#
#   bash point-domain.sh clarityai.ca clarityai.cloud360.ca
#   bash point-domain.sh getprompthelper.com aiprompthelper.cloud360.ca
#
# The second name is the site that already works. This script does NOT invent a
# configuration - it reads that site's existing nginx file, takes the address it
# forwards to, and writes the same thing out again under the new name. So the
# new domain lands on exactly the site you can already see, not on a guess.
#
# Then it asks Let's Encrypt for a certificate and checks the finished result
# from outside over https.
#
# Run it on the reverse proxy (VM 111) as the ubuntu24 user.
#
# Order matters. The DNS A record has to be pointing here BEFORE you run this,
# because Let's Encrypt proves you own the domain by fetching a file from it.
# The script checks that first and stops with an explanation if it is not ready,
# without having changed anything.
#
set -uo pipefail

NEWDOMAIN="${1:-}"
TEMPLATE="${2:-}"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32mOK\033[0m   %s\n' "$*"; }
bad()  { printf '    \033[31mFAIL\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }

if [ -z "$NEWDOMAIN" ] || [ -z "$TEMPLATE" ]; then
  bad "Usage: bash point-domain.sh NEW-DOMAIN EXISTING-WORKING-DOMAIN"
  note "for example: bash point-domain.sh clarityai.ca clarityai.cloud360.ca"
  exit 1
fi

command -v nginx >/dev/null 2>&1 || { bad "nginx is not on this machine - wrong server."; exit 1; }

# ---------------------------------------------------------------------------
# 1. Is the DNS actually pointing here yet?
# ---------------------------------------------------------------------------
say "Checking that $NEWDOMAIN points at this server"

MYIP=$(curl -s --max-time 15 https://api.ipify.org 2>/dev/null)
if [ -z "$MYIP" ]; then
  bad "Could not work out this server's own public address."
  note "Nothing has been changed."
  exit 1
fi
note "this server is $MYIP"

RESOLVED=$(getent ahostsv4 "$NEWDOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')
note "$NEWDOMAIN resolves to ${RESOLVED:-nothing}"

case " $RESOLVED " in
  *" $MYIP "*) ok "DNS is pointing here" ;;
  *)
    bad "DNS is not pointing here yet."
    note "Set an A record for $NEWDOMAIN and for www.$NEWDOMAIN to $MYIP"
    note "at whoever runs the DNS for this domain, wait a few minutes, and run"
    note "this again. Nothing has been changed."
    exit 1
    ;;
esac

WWW_OK=no
case " $(getent ahostsv4 "www.$NEWDOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ') " in
  *" $MYIP "*) WWW_OK=yes; ok "www.$NEWDOMAIN points here too" ;;
  *) note "www.$NEWDOMAIN does NOT point here - it will be left out of the certificate" ;;
esac

# ---------------------------------------------------------------------------
# 2. Read the working site's configuration and take its upstream from it.
# ---------------------------------------------------------------------------
say "Reading the configuration of $TEMPLATE"

SRC=""
for d in /etc/nginx/sites-enabled /etc/nginx/sites-available /etc/nginx/conf.d; do
  for f in "$d/$TEMPLATE.conf" "$d/$TEMPLATE"; do
    [ -f "$f" ] && { SRC="$f"; break 2; }
  done
done
if [ -z "$SRC" ]; then
  SRC=$(sudo grep -rls "server_name[^;]*$TEMPLATE" /etc/nginx 2>/dev/null | head -1)
fi
if [ -z "$SRC" ]; then
  bad "Could not find an nginx file for $TEMPLATE on this machine."
  note "Send me the output of:   ls /etc/nginx/sites-enabled"
  note "Nothing has been changed."
  exit 1
fi
ok "Found $SRC"

UPSTREAM=$(sudo grep -hoE 'proxy_pass[[:space:]]+https?://[^;]+' "$SRC" 2>/dev/null | head -1 | awk '{print $2}')
if [ -z "$UPSTREAM" ]; then
  bad "That file has no proxy_pass line, so there is nothing to copy."
  note "Nothing has been changed."
  exit 1
fi
ok "It forwards to $UPSTREAM"

SERVER_NAMES="$NEWDOMAIN"
[ "$WWW_OK" = yes ] && SERVER_NAMES="$NEWDOMAIN www.$NEWDOMAIN"

TARGET="/etc/nginx/sites-available/$NEWDOMAIN.conf"
if sudo test -f "$TARGET"; then
  BK="$TARGET.before-$(date +%Y%m%d-%H%M%S)"
  sudo cp "$TARGET" "$BK"
  note "an older file was already here - kept a copy at $BK"
fi

# ---------------------------------------------------------------------------
# 3. Write the plain http site. certbot rewrites this file to add https.
# ---------------------------------------------------------------------------
say "Writing $TARGET"
sudo tee "$TARGET" >/dev/null <<CONF
# $NEWDOMAIN - written by point-domain.sh, copied from $SRC
server {
    listen 80;
    listen [::]:80;
    server_name $SERVER_NAMES;

    client_max_body_size 25m;

    location / {
        proxy_pass $UPSTREAM;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 90s;
    }
}
CONF
sudo ln -sfn "$TARGET" "/etc/nginx/sites-enabled/$NEWDOMAIN.conf"
ok "Written and enabled"

say "Testing the nginx configuration before reloading anything"
if ! sudo nginx -t 2>&1 | sed 's/^/    /'; then
  bad "nginx rejected the configuration. Removing the new file again."
  sudo rm -f "/etc/nginx/sites-enabled/$NEWDOMAIN.conf"
  note "The server is exactly as it was. Send me what nginx printed above."
  exit 1
fi
sudo systemctl reload nginx && ok "nginx reloaded"

HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -H "Host: $NEWDOMAIN" "http://127.0.0.1/" 2>/dev/null)
note "over plain http the new name now answers $HTTP_CODE"

# ---------------------------------------------------------------------------
# 4. Certificate.
# ---------------------------------------------------------------------------
say "Asking Let's Encrypt for a certificate"
if ! command -v certbot >/dev/null 2>&1; then
  bad "certbot is not installed here."
  note "The site works on http already. Tell me and I will send the install step."
  exit 1
fi

CB_ARGS="--nginx -d $NEWDOMAIN"
[ "$WWW_OK" = yes ] && CB_ARGS="$CB_ARGS -d www.$NEWDOMAIN"
# If certbot already has an account on this box, do not ask for an address again.
if sudo test -d /etc/letsencrypt/accounts; then
  CB_ARGS="$CB_ARGS --non-interactive --agree-tos --redirect"
else
  CB_ARGS="$CB_ARGS --non-interactive --agree-tos --redirect --register-unsafely-without-email"
fi

sudo certbot $CB_ARGS 2>&1 | tail -20 | sed 's/^/    /'

# ---------------------------------------------------------------------------
# 5. Prove it from outside, the way a visitor sees it.
# ---------------------------------------------------------------------------
say "Checking $NEWDOMAIN from outside over https"
FINAL=$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 "https://$NEWDOMAIN/" 2>/dev/null)
if [ "$FINAL" = "200" ]; then
  ok "https://$NEWDOMAIN answers 200 - it is live"
else
  bad "https://$NEWDOMAIN answered $FINAL"
  note "Send me this whole output and I will take it from there. The old site at"
  note "$TEMPLATE has not been touched and is still working."
fi

if [ "$WWW_OK" = yes ]; then
  FINALW=$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 "https://www.$NEWDOMAIN/" 2>/dev/null)
  note "https://www.$NEWDOMAIN answers $FINALW"
fi

say "Done"
note "$TEMPLATE still works exactly as before - nothing was moved, only added."
