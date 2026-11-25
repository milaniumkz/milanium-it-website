#!/usr/bin/env bash
set -euo pipefail
host=milanium.kz
ip=89.126.192.185
root=/var/www/milanium.kz
conf=/etc/nginx/conf.d/milanium.kz.conf
arch="${1:?}"
check_sum="${2:?}"
[[ "$arch" =~ ^/tmp/milanium\.release\.[A-Za-z0-9]{10}$ && "$check_sum" =~ ^[a-f0-9]{64}$ ]]
test "$(id -u)" = 0
test -f "$arch" && test ! -L "$arch"
created=0
config_enabled=0
rollback() {
  code=$?
  trap - EXIT
  if (( code != 0 )); then
    if (( config_enabled )); then
      rm -f -- "$conf"
      if nginx -t >/dev/null 2>&1; then systemctl reload nginx || echo 'Rollback reload requires operator review'; fi
    fi
    if (( created )); then mv -T -- "$root" "${root}.failed.$(date +%s)" || true; fi
    echo 'MILANIUM publish was not completed.'
  fi
  rm -f -- "$arch"
  exit "$code"
}
trap rollback EXIT
exec 9>/run/lock/milanium-publish.lock
flock -n 9
printf '%s  %s\n' "$check_sum" "$arch" | sha256sum --check --status
test -d /etc/nginx/conf.d

extract_site() {
python3 - "$arch" "$1" "$host" <<'PY'
import pathlib, stat, sys, zipfile
from shutil import copyfileobj
with zipfile.ZipFile(sys.argv[1]) as z:
    for info in z.infolist():
        rel=pathlib.PurePosixPath(info.filename)
        if not rel.parts or rel.parts[0] != "site": continue
        assert not any(part in ("..",".") for part in rel.parts)
        assert not stat.S_ISLNK(info.external_attr >> 16)
        target=pathlib.Path(sys.argv[2],*rel.parts)
        if info.is_dir():
            target.mkdir(parents=True,exist_ok=True)
        else:
            target.parent.mkdir(parents=True,exist_ok=True)
            with z.open(info) as f,target.open('xb') as g: copyfileobj(f,g)
            target.chmod(0o644)

site = pathlib.Path(sys.argv[2], "site")
old_origin = b"https://milanium.89.126.192.185.sslip.io"
new_origin = b"https://" + sys.argv[3].encode("ascii")
for path in site.rglob("*"):
    if path.suffix not in {".html", ".txt", ".xml"}:
        continue
    data = path.read_bytes().replace(old_origin, new_origin)
    if "_not-found" not in path.relative_to(site).as_posix() and path.name != "404.html":
        data = data.replace(b"noindex, follow", b"index, follow")
    path.write_bytes(data)
PY
}

neighbor() {
  curl -fsS --max-time 15 -o /dev/null https://mtaxi.89.126.192.185.sslip.io/
  curl -fsS --max-time 15 -o /dev/null https://mbusiness.89.126.192.185.sslip.io:8443/
}

exchange_sites() {
  python3 - "$1" "$2" <<'PY'
import ctypes
import os
import sys

renameat2 = ctypes.CDLL(None, use_errno=True).renameat2
renameat2.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint)
renameat2.restype = ctypes.c_int
at_fdcwd = -100
rename_exchange = 2
if renameat2(at_fdcwd, os.fsencode(sys.argv[1]), at_fdcwd, os.fsencode(sys.argv[2]), rename_exchange):
    raise OSError(ctypes.get_errno(), "Could not atomically exchange MILANIUM releases")
PY
}

if [[ -f "$root/site/index.html" && -f "$conf" ]]; then
  # Reuse the existing host and certificate. Stage next to the served directory.
  test ! -L "$root" && test ! -L "$root/site" && test ! -L "$conf"
  grep -Fx "    root $root/site;" "$conf" >/dev/null
  nginx -t
  neighbor
  staged="$(mktemp -d "$root/release.XXXXXXXXXX")"
  exchanged=0
  finish_update() {
    local status=$?
    trap - EXIT
    if (( status != 0 )); then
      if (( ! exchanged )) || exchange_sites "$root/site" "$staged/site"; then
        rm -rf -- "$staged"
      else
        echo "MILANIUM rollback requires operator review: $staged/site" >&2
      fi
    fi
    rm -f -- "$arch"
    exit "$status"
  }
  trap finish_update EXIT
  extract_site "$staged"
  test -s "$staged/site/index.html"
  expected="$(sha256sum "$staged/site/index.html" | cut -d ' ' -f 1)"
  exchange_sites "$root/site" "$staged/site"
  exchanged=1
  actual="$(curl --noproxy '*' -fsS --max-time 15 --resolve "$host:443:$ip" "https://$host/" | sha256sum | cut -d ' ' -f 1)"
  test "$actual" = "$expected"
  curl -fsS --max-time 15 "https://$host/robots.txt" >/dev/null
  neighbor
  echo "Verified HTTPS: https://$host/"
  echo "Previous MILANIUM release: $staged/site"
  exit 0
fi

for p in "$root" "$conf" /etc/nginx/sites-available/milanium.kz.conf /etc/nginx/sites-enabled/milanium.kz.conf; do
  if [[ -e "$p" || -L "$p" ]]; then echo 'MILANIUM path is already occupied; no overwrite'; exit 1; fi
done
nginx -t
# The HTTP-01 challenge must reach this VPS via the public domain.
dns_ipv4="$(getent ahostsv4 "$host" | awk '{print $1}' | sort -u)"
if [[ "$dns_ipv4" != "$ip" ]]; then
  echo "Expected $host to resolve only to IPv4 address $ip" >&2
  exit 1
fi
nginx_config="$(nginx -T 2>/dev/null)"
if awk -v host="$host" '
    $1 == "server_name" {
        for (i = 2; i <= NF; i++) {
            sub(/;$/, "", $i)
            if ($i == host) found = 1
        }
    }
    END { exit !found }
' <<<"$nginx_config"; then
  echo 'Hostname already configured'; exit 1
fi

neighbor
master="$(systemctl show nginx -p MainPID --value)"
test "$master" -gt 0
install -d -m 755 "$root"
created=1
extract_site "$root"
test -s "$root/site/index.html"
install -d -m 755 "$root/acme/.well-known/acme-challenge"
printf '%s' milanium-acme-ready > "$root/acme/.well-known/acme-challenge/preflight"
write_conf() {
  local tls="$1"
  local tmp
  tmp="$(mktemp "$root/nginx.XXXXXXXXXX")"
  cat >"$tmp" <<NGINX
server {
    listen 80;
    server_name $host;
    location ^~ /.well-known/acme-challenge/ { root $root/acme; try_files \$uri =404; }
    location / { return 308 https://$host\$request_uri; }
}
NGINX
  if [[ "$tls" == yes ]]; then
    cat >>"$tmp" <<NGINX
server {
    listen 443 ssl;
    server_name $host;
    ssl_certificate /etc/letsencrypt/live/$host/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$host/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    root $root/site;
    index index.html;
    location / { try_files \$uri \$uri/ \$uri.html =404; }
}
NGINX
  fi
  chmod 644 "$tmp"
  if (( config_enabled == 0 )); then
    ln -- "$tmp" "$conf"
    config_enabled=1
    rm -- "$tmp"
  else
    mv -T -- "$tmp" "$conf"
  fi
  nginx -t
  nginx -T 2>&1 | grep -F -- "# configuration file $conf:" >/dev/null
  systemctl reload nginx
  test "$(systemctl show nginx -p MainPID --value)" = "$master"
}
write_conf no
echo 'Waiting for the new MILANIUM-only HTTP route after the graceful reload.'
for attempt in 1 2 3 4 5 6 7 8; do
  probe="$(curl --noproxy '*' -fsS --max-time 5 --resolve "$host:80:$ip" "http://$host/.well-known/acme-challenge/preflight" 2>/dev/null || true)"
  if [[ "$probe" == milanium-acme-ready ]]; then break; fi
  sleep 2
done
if [[ "$probe" != milanium-acme-ready ]]; then
  curl --noproxy '*' -sS --max-time 5 --resolve "$host:80:$ip" -o /dev/null -w 'MILANIUM challenge status: %{http_code}\n' "http://$host/.well-known/acme-challenge/preflight" || true
  exit 1
fi
certbot certonly --webroot -w "$root/acme" --cert-name "$host" -d "$host" --non-interactive --agree-tos --register-unsafely-without-email --no-directory-hooks --pre-hook true --post-hook true --deploy-hook 'nginx -t && systemctl reload nginx'
write_conf yes
expected="$(sha256sum "$root/site/index.html" | cut -d ' ' -f 1)"
actual="$(curl --noproxy '*' -fsS --retry 6 --retry-all-errors --retry-delay 2 --max-time 10 --resolve "$host:443:$ip" "https://$host/" | sha256sum | cut -d ' ' -f 1)"
test "$actual" = "$expected"
curl -fsS --max-time 15 "https://$host/robots.txt" >/dev/null
neighbor
rm -f "$root/acme/.well-known/acme-challenge/preflight"
echo "Verified HTTPS: https://$host/"
echo "MTaxi and MBusiness HTTPS checks passed before and after. Nginx master stayed unchanged."
