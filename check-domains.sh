#!/usr/bin/env bash
#
# Tell me, in one screen, whether the vanity domains on this reverse proxy are
# healthy - and if they are not, which of the two faults it is this time.
#
#   bash check-domains.sh
#   bash check-domains.sh mydomain.com another.ca      (to check specific ones)
#
# Run it on the reverse proxy (VM 111) as the ubuntu24 user. It changes nothing.
#
# There are only ever two things wrong when a domain here shows the wrong site
# or says "Not secure", and they are independent of each other:
#
#   BLOCK   nginx has no server_name for the domain, so the request falls
#           through to the default site - which on this box is AgBuySell.
#   CERT    the certificate being served is the Cloudflare Origin certificate.
#           That one is trusted by Cloudflare's edge and by nothing else, so a
#           domain pointed straight at this server shows "Not secure" with it.
#
# Fixing one without the other still looks broken, which is why this keeps
# coming back. This script always reports both.
#
set -uo pipefail

DOMAINS=("$@")
if [ ${#DOMAINS[@]} -eq 0 ]; then
  DOMAINS=(clarityai.ca www.clarityai.ca getprompthelper.com www.getprompthelper.com)
fi

command -v nginx >/dev/null 2>&1 || { echo "nginx is not on this machine - wrong server."; exit 1; }

MYIP=$(curl -s --max-time 15 https://api.ipify.org 2>/dev/null)
echo "This server is $(hostname), going out as ${MYIP:-unknown}"

CONF=$(sudo nginx -T 2>/dev/null)

# Say plainly whether this is the box that matters. Run on the wrong machine,
# every verdict below would be technically true and completely misleading:
# nothing is configured here, so everything reads as MISSING.
if printf '%s\n' "$CONF" | grep -q 'agbuysell\|liquoronline'; then
  echo "This is the reverse proxy - the verdicts below are about the live estate."
else
  echo
  echo "WARNING: this machine does not serve the estate's sites, so it is not the"
  echo "reverse proxy. Everything below will read as missing simply because it is"
  echo "not configured here. Log in to the machine whose prompt reads nginx-mern."
fi
echo

# Pull out every name nginx actually serves, one per line. Not a grep for the
# domain against the raw config: server_name is not always the first thing on
# its line - "listen 443 ssl; server_name backups.cloud360.ca;" is real config
# on this box - and a line-anchored search reports names like that as missing
# when they are plainly there. Comments are stripped first so a domain
# mentioned in one is not mistaken for a live block.
SERVED=$(printf '%s\n' "$CONF" \
         | sed 's/#.*//' \
         | grep -oE 'server_name[[:space:]]+[^;]*' \
         | sed 's/^server_name[[:space:]]*//' \
         | tr ' \t' '\n\n' | sed '/^$/d' | sort -u)

# Exact match, or a wildcard block one level up that would cover it.
is_served() {
  printf '%s\n' "$SERVED" | grep -qxF "$1" && return 0
  printf '%s\n' "$SERVED" | grep -qxF "*.${1#*.}" && return 0
  return 1
}

problems=0

for d in "${DOMAINS[@]}"; do
  echo "------------------------------------------------------------"
  echo "$d"

  ip=$(getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')
  if [ -z "$ip" ]; then
    printf '  %-8s %s\n' "DNS" "does not resolve at all"
    problems=$((problems + 1))
    continue
  fi
  HERE=no
  case " $ip " in
    *" $MYIP "*) HERE=yes; printf '  %-8s %s\n' "DNS" "$ip  (points here)" ;;
    *)           printf '  %-8s %s\n' "DNS" "$ip  (points somewhere else - this server does not serve it)" ;;
  esac

  # Only a fault when the traffic actually arrives here. A domain living on
  # another host has no business having a block on this one, and reporting that
  # as a problem sends you looking for a fault that does not exist.
  if is_served "$d"; then
    printf '  %-8s %s\n' "BLOCK" "nginx has a server block for this name"
  elif [ "$HERE" = yes ]; then
    printf '  %-8s %s\n' "BLOCK" "MISSING - nginx has no server_name for this name, so it"
    printf '  %-8s %s\n' "" "falls through to the default site (AgBuySell)"
    problems=$((problems + 1))
  else
    printf '  %-8s %s\n' "BLOCK" "none here, which is correct - it is served elsewhere"
  fi

  # -k on purpose: the whole question is what certificate is being served, and
  # refusing to connect because it is the wrong one answers nothing.
  code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 20 "https://$d/" 2>/dev/null)
  issuer=$(echo | timeout 20 openssl s_client -connect "$d:443" -servername "$d" 2>/dev/null \
           | openssl x509 -noout -issuer -enddate 2>/dev/null | tr '\n' ' ')
  case "$issuer" in
    "")                 printf '  %-8s %s\n' "CERT" "could not read a certificate"; problems=$((problems + 1)) ;;
    *Cloudflare*)       printf '  %-8s %s\n' "CERT" "Cloudflare Origin cert - browsers WILL say Not secure"
                        printf '  %-8s %s\n' "" "$issuer"
                        problems=$((problems + 1)) ;;
    *"Let's Encrypt"*|*R1[0-9]*|*E[0-9]*)
                        printf '  %-8s %s\n' "CERT" "real public certificate  $issuer" ;;
    *)                  printf '  %-8s %s\n' "CERT" "$issuer" ;;
  esac

  # Which site actually answered. The AgBuySell app stamps its own address into
  # this header, so seeing it on another domain is proof of the fall-through.
  landed=$(curl -sk -I --max-time 20 "https://$d/" 2>/dev/null \
           | grep -i '^access-control-allow-origin' | tr -d '\r' | awk '{print $2}')
  title=$(curl -sk --max-time 20 "https://$d/" 2>/dev/null \
          | tr -d '\n' | sed -n 's/.*<title[^>]*>\([^<]*\)<\/title>.*/\1/p' | cut -c1-70)
  printf '  %-8s %s\n' "HTTP" "$code"
  [ -n "$title" ]  && printf '  %-8s %s\n' "PAGE" "$title"
  [ -n "$landed" ] && printf '  %-8s %s\n' "ORIGIN" "$landed"
  case "$landed" in
    *agbuysell*) printf '  %-8s %s\n' "" "^ that is the AgBuySell app answering, not this domain's site"
                 problems=$((problems + 1)) ;;
  esac
done

echo "------------------------------------------------------------"
if [ "$problems" -eq 0 ]; then
  echo "All good - every name has its own block and a real certificate."
else
  echo "$problems problem(s) above."
  echo
  echo "To fix a domain, run the pointer script with the working site to copy from:"
  echo "  bash point-domain.sh clarityai.ca         clarityai.cloud360.ca"
  echo "  bash point-domain.sh getprompthelper.com  aiprompthelper.cloud360.ca"
fi
