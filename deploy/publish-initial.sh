#!/usr/bin/env bash
set -euo pipefail
host=milanium.89.126.192.185.sslip.io
ip=89.126.192.185
root=/var/www/milanium
conf=/etc/nginx/conf.d/milanium.conf
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
for p in "$root" "$conf" /etc/nginx/sites-available/milanium.conf /etc/nginx/sites-enabled/milanium.conf; do
  if [[ -e "$p" || -L "$p" ]]; then echo 'MILANIUM path is already occupied; no overwrite'; exit 1; fi
done
nginx -t
if nginx -T 2>/dev/null | grep -F -- "$host" >/dev/null; then
  echo 'Hostname already configured'; exit 1
fi
neighbor() {
  curl -fsS --max-time 15 -o /dev/null https://mtaxi.89.126.192.185.sslip.io/
  curl -fsS --max-time 15 -o /dev/null https://mbusiness.89.126.192.185.sslip.io:8443/
}
neighbor
master="$(systemctl show nginx -p MainPID --value)"
test "$master" -gt 0
install -d -m 755 "$root"
created=1
python3 - "$arch" "$root" <<'PY'
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
PY
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
test "$(curl -fsS --max-time 12 --resolve "$host:80:$ip" "http://$host/.well-known/acme-challenge/preflight")" = milanium-acme-ready
certbot certonly --webroot -w "$root/acme" --cert-name "$host" -d "$host" --non-interactive --agree-tos --register-unsafely-without-email --no-directory-hooks --pre-hook true --post-hook true --deploy-hook true
write_conf yes
expected="$(sha256sum "$root/site/index.html" | cut -d ' ' -f 1)"
actual="$(curl -fsS --retry 2 --max-time 15 --resolve "$host:443:$ip" "https://$host/" | sha256sum | cut -d ' ' -f 1)"
test "$actual" = "$expected"
curl -fsS --max-time 15 "https://$host/robots.txt" >/dev/null
neighbor
rm -f "$root/acme/.well-known/acme-challenge/preflight"
echo "Verified HTTPS: https://$host/"
echo "MTaxi and MBusiness HTTPS checks passed before and after. Nginx master stayed unchanged."
