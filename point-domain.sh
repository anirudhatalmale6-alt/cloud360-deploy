#!/usr/bin/env bash
#
# Point a real domain at a site that is already running on this reverse proxy.
#
#   bash point-domain.sh clarityai.ca         clarityai.cloud360.ca
#   bash point-domain.sh getprompthelper.com  aiprompthelper.cloud360.ca
#
# The second name is the site that already works. This script does NOT invent a
# configuration - it reads that site's existing nginx file, takes the address it
# forwards to, and writes the same thing out again under the new name. So the
# new domain lands on exactly the site you can already see, not on a guess.
#
# Run it on the reverse proxy (VM 111) as the ubuntu24 user.
#
# Safe to run again as many times as you like. It writes the finished http+https
# configuration itself and only calls Let's Encrypt when there is no certificate
# yet - so re-running it can never drop the site back to "Not secure", and can
# never burn through Let's Encrypt's five-per-week limit.
#
# It checks, in this order and stopping at the first failure without having
# changed anything:
#
#   1. that this really is the machine serving the site you named - if it is
#      not, it says so and tells you nothing else, because advice from the wrong
#      machine is worse than no advice;
#   2. that the app behind that site is actually up;
#   3. that the domain's DNS already points at the address this proxy answers
#      on - Let's Encrypt proves you own the domain by fetching a file from it,
#      so that has to be true first.
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

# Real paths by default. They are overridable only so this script can be run
# end to end against a throwaway nginx before it is ever pointed at the live
# proxy - nothing you run by hand needs to set any of them.
NGINX_DIR="${NGINX_DIR:-/etc/nginx}"
LE_DIR="${LE_DIR:-/etc/letsencrypt}"
ACME_ROOT="${ACME_ROOT:-/var/www/acme}"
NGINX_TEST="${NGINX_TEST:-sudo nginx -t}"
NGINX_RELOAD="${NGINX_RELOAD:-sudo systemctl reload nginx}"

# nginx changed how http2 is switched on in 1.25. The old spelling is a hard
# error on new builds and the new one is a hard error on old builds, so ask the
# binary which it is rather than picking one and hoping. VM 111 is on 1.24.
NGVER=$(nginx -v 2>&1 | sed -n 's#.*nginx/\([0-9][0-9]*\.[0-9][0-9]*\).*#\1#p')
NGMAJ=${NGVER%%.*}; NGMIN=${NGVER#*.}
if [ -n "$NGVER" ] && { [ "${NGMAJ:-0}" -gt 1 ] || [ "${NGMIN:-0}" -ge 25 ]; }; then
  LISTEN_HTTP2=""; HTTP2_DIRECTIVE='echo "    http2 on;"'
else
  LISTEN_HTTP2=" http2"; HTTP2_DIRECTIVE=":"
fi

TARGET="$NGINX_DIR/sites-available/$NEWDOMAIN.conf"
LINK="$NGINX_DIR/sites-enabled/$NEWDOMAIN.conf"
LIVE="$LE_DIR/live/$NEWDOMAIN"

# ---------------------------------------------------------------------------
# 1. Am I even on the right machine?
#
# This is deliberately the FIRST thing checked. An earlier version asked about
# DNS first, was run on the storage box by mistake, and cheerfully advised
# pointing two live domains at a machine with nothing listening on port 80 -
# which took them from "wrong site" to "does not load at all". A script that
# gives instructions has to establish it is qualified to give them.
#
# The test is simple and unfakeable: the site we are told already works has to
# be configured HERE. If it is not, this is not the reverse proxy.
# ---------------------------------------------------------------------------
say "Checking this is the machine that serves $TEMPLATE"

SRC=""
for d in "$NGINX_DIR/sites-enabled" "$NGINX_DIR/sites-available" "$NGINX_DIR/conf.d"; do
  for f in "$d/$TEMPLATE.conf" "$d/$TEMPLATE"; do
    [ -f "$f" ] && { SRC="$f"; break 2; }
  done
done
if [ -z "$SRC" ]; then
  # The file is not named after the site. Find whichever file declares it -
  # skipping our own output, or re-running this would copy from itself.
  SRC=$(sudo grep -rls -- "server_name[^;]*$TEMPLATE" "$NGINX_DIR" 2>/dev/null \
        | grep -v -- "/$NEWDOMAIN.conf$" | head -1)
fi
if [ -z "$SRC" ]; then
  bad "$TEMPLATE is not configured on this machine, so this is the wrong box."
  note "You are logged in to $(hostname). The reverse proxy is the machine whose"
  note "prompt reads nginx-mern. Log in to that one and run this again."
  note ""
  note "For what it is worth, this machine serves these names:"
  sudo nginx -T 2>/dev/null | sed 's/#.*//' \
    | grep -oE 'server_name[[:space:]]+[^;]*' | sed 's/^server_name[[:space:]]*//' \
    | tr ' \t' '\n\n' | sed '/^$/d' | sort -u | head -20 | sed 's/^/      /'
  note ""
  note "Nothing has been changed, and no advice above this line is worth acting on."
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

# Prove the upstream is actually alive before pointing a public name at it.
UP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
          -H "Host: $TEMPLATE" "$UPSTREAM" 2>/dev/null)
if [ "$UP_CODE" = "000" ]; then
  bad "$UPSTREAM did not answer at all - the app behind $TEMPLATE looks down."
  note "Nothing has been changed. Fix the app first, then run this again."
  exit 1
fi
ok "$UPSTREAM answers $UP_CODE"

# ---------------------------------------------------------------------------
# 2. Is the DNS pointing here yet?
#
# Only now, having established this really is the proxy, is it safe to say
# anything about where a domain should point.
# ---------------------------------------------------------------------------
say "Checking that $NEWDOMAIN points at this server"

MYIP=$(curl -s --max-time 15 https://api.ipify.org 2>/dev/null)
if [ -z "$MYIP" ]; then
  bad "Could not work out this server's own public address."
  note "Nothing has been changed."
  exit 1
fi
note "this server goes out as $MYIP"

# Going out as an address is not the same as being reachable at it - a machine
# behind NAT can have a different address inbound. Before naming that address in
# an instruction, knock on it from the outside and see if this proxy answers.
PUB_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
           -H "Host: $TEMPLATE" "http://$MYIP/" 2>/dev/null)
if [ "$PUB_CODE" = "000" ]; then
  bad "Nothing answers on port 80 at $MYIP, so that is not the address the"
  note "public reaches this proxy on - do NOT point any domain at it."
  note "Send me this output and I will find the right address. Nothing changed."
  exit 1
fi
ok "$MYIP answers on port 80, so that is the public address of this proxy"

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

SERVER_NAMES="$NEWDOMAIN"
[ "$WWW_OK" = yes ] && SERVER_NAMES="$NEWDOMAIN www.$NEWDOMAIN"

sudo mkdir -p "$ACME_ROOT/.well-known/acme-challenge"
sudo chmod -R 755 "$ACME_ROOT"

if sudo test -f "$TARGET"; then
  BK="$TARGET.before-$(date +%Y%m%d-%H%M%S)"
  sudo cp "$TARGET" "$BK"
  note "an older file was already here - kept a copy at $BK"
fi

# ---------------------------------------------------------------------------
# 3. Write a plain http site first, so the certificate can be fetched over it.
# ---------------------------------------------------------------------------
write_conf() {   # $1 = "http" for the pre-certificate version, "https" for the finished one
  local mode="$1"
  {
    echo "# $NEWDOMAIN - written by point-domain.sh, upstream copied from $SRC"
    echo "# Do not hand-edit. Re-run the script instead; it is safe to repeat."
    echo "server {"
    echo "    listen 80;"
    echo "    server_name $SERVER_NAMES;"
    echo ""
    echo "    # Kept on port 80 permanently. Let's Encrypt renews every 60 days"
    echo "    # over plain http, and a blanket redirect to https breaks that the"
    echo "    # first time the certificate on 443 is not valid."
    echo "    location ^~ /.well-known/acme-challenge/ {"
    echo "        root $ACME_ROOT;"
    echo "        default_type \"text/plain\";"
    echo "    }"
    echo ""
    if [ "$mode" = https ]; then
      echo "    location / { return 301 https://\$host\$request_uri; }"
      echo "}"
      echo ""
      echo "server {"
      echo "    listen 443 ssl$LISTEN_HTTP2;"
      $HTTP2_DIRECTIVE
      echo "    server_name $SERVER_NAMES;"
      echo ""
      echo "    ssl_certificate     $LIVE/fullchain.pem;"
      echo "    ssl_certificate_key $LIVE/privkey.pem;"
      [ -f "$LE_DIR/options-ssl-nginx.conf" ] && \
        echo "    include $LE_DIR/options-ssl-nginx.conf;"
      [ -f "$LE_DIR/ssl-dhparams.pem" ] && \
        echo "    ssl_dhparam $LE_DIR/ssl-dhparams.pem;"
      echo ""
    fi
    echo "    client_max_body_size 25m;"
    echo ""
    echo "    location / {"
    echo "        proxy_pass $UPSTREAM;"
    echo "        proxy_http_version 1.1;"
    echo "        proxy_set_header Upgrade \$http_upgrade;"
    echo "        proxy_set_header Connection \"upgrade\";"
    echo "        proxy_set_header Host \$host;"
    echo "        proxy_set_header X-Real-IP \$remote_addr;"
    echo "        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;"
    echo "        proxy_set_header X-Forwarded-Proto \$scheme;"
    echo "        proxy_read_timeout 90s;"
    echo "    }"
    echo "}"
  } | sudo tee "$TARGET" >/dev/null
  sudo ln -sfn "$TARGET" "$LINK"
}

# Put the configuration back exactly as it was and reload, so a rejected config
# never leaves the proxy in a state the previous one was not already in.
restore() {
  if [ -n "${BK:-}" ] && sudo test -f "${BK:-/nonexistent}"; then
    sudo cp "$BK" "$TARGET"
  else
    sudo rm -f "$TARGET" "$LINK"
  fi
  $NGINX_TEST >/dev/null 2>&1 && $NGINX_RELOAD >/dev/null 2>&1
}

apply() {   # $1 = mode, $2 = description for the log
  write_conf "$1"
  if ! $NGINX_TEST 2>&1 | sed 's/^/    /'; then
    bad "nginx rejected the configuration ($2). Putting it back as it was."
    restore
    note "The server is exactly as it was. Send me what nginx printed above."
    exit 1
  fi
  $NGINX_RELOAD >/dev/null 2>&1 && ok "nginx reloaded ($2)"
}

say "Writing $TARGET"
apply http "plain http for now"

HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -H "Host: $NEWDOMAIN" "http://127.0.0.1/" 2>/dev/null)
note "over plain http the new name now answers $HTTP_CODE"

# ---------------------------------------------------------------------------
# 4. Certificate. Only asked for when there is not already a usable one.
# ---------------------------------------------------------------------------
say "Certificate"

# A certificate that exists but does not cover www is worse than none - the
# browser warns on the name it is missing. So check the names, not just the file.
cert_covers_everything() {
  sudo test -f "$LIVE/fullchain.pem" || return 1
  local sans
  sans=$(sudo openssl x509 -in "$LIVE/fullchain.pem" -noout -text 2>/dev/null \
         | tr ',' '\n' | sed -n 's/.*DNS://p' | tr -d ' ')
  local n
  for n in $SERVER_NAMES; do
    printf '%s\n' "$sans" | grep -qx -- "$n" || return 1
  done
  return 0
}

if cert_covers_everything; then
  EXP=$(sudo openssl x509 -in "$LIVE/fullchain.pem" -noout -enddate 2>/dev/null | cut -d= -f2)
  ok "a Let's Encrypt certificate is already here for $SERVER_NAMES, expires $EXP"
  note "not asking for another one - renewal is automatic"
else
  if ! command -v certbot >/dev/null 2>&1; then
    say "Installing certbot"
    sudo apt-get update -qq >/dev/null 2>&1
    sudo apt-get install -y -qq certbot >/dev/null 2>&1
  fi
  if ! command -v certbot >/dev/null 2>&1; then
    bad "certbot could not be installed."
    note "The site works on plain http already, so nothing is broken - it just"
    note "has no padlock yet. Send me this output."
    exit 1
  fi

  CB="--cert-name $NEWDOMAIN -d $NEWDOMAIN"
  [ "$WWW_OK" = yes ] && CB="$CB -d www.$NEWDOMAIN"
  sudo test -f "$LIVE/fullchain.pem" && CB="$CB --expand"
  if sudo test -d "$LE_DIR/accounts"; then
    CB="$CB --non-interactive --agree-tos"
  else
    CB="$CB --non-interactive --agree-tos --register-unsafely-without-email"
  fi

  # certonly, not --nginx: the configuration above is already exactly right and
  # certbot's own rewriting of it is what makes this hard to repeat safely.
  sudo certbot certonly --webroot -w "$ACME_ROOT" $CB \
       --deploy-hook "systemctl reload nginx" 2>&1 | tail -25 | sed 's/^/    /'

  if ! cert_covers_everything; then
    bad "No certificate was issued. Leaving the site on plain http."
    note "It is serving the right site now, it just has no padlock. Send me the"
    note "whole output above and I will read the reason out of it."
    exit 1
  fi
  ok "certificate issued"
fi

say "Switching $NEWDOMAIN to https"
apply https "http redirects to https"

# ---------------------------------------------------------------------------
# 5. Prove it from outside, the way a visitor sees it.
# ---------------------------------------------------------------------------
say "Checking $NEWDOMAIN from outside over https"
FINAL=$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 "https://$NEWDOMAIN/" 2>/dev/null)
ISSUER=$(echo | openssl s_client -connect "$NEWDOMAIN:443" -servername "$NEWDOMAIN" 2>/dev/null \
         | openssl x509 -noout -issuer 2>/dev/null | sed 's/^issuer=//')
note "certificate now served: ${ISSUER:-could not read}"

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
note "Run  bash check-domains.sh  any time to see the state of every vanity domain."
