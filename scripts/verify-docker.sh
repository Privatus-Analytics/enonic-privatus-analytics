#!/usr/bin/env bash
# Builds the app and a test fixture app in Docker, runs a real Enonic XP 8 with Content Studio, and checks
# what the app adds to the <head> of each test site.
#
#   ./scripts/verify-docker.sh            # XP 8.1.2, port 18080
#   XP_IMAGE=enonic/xp:8.1.2-ubuntu PORT=18081 KEEP=1 ./scripts/verify-docker.sh
#
# KEEP=1 leaves the container running afterwards (log in at http://localhost:$PORT/admin as su, with the
# password written to build/verify/su-password).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
XP_IMAGE="${XP_IMAGE:-enonic/xp:8.1.2-ubuntu}"
JDK_IMAGE="${JDK_IMAGE:-eclipse-temurin:25-jdk}"
CS_VERSION="${CS_VERSION:-6.0.4}"
PORT="${PORT:-18080}"
NAME="${NAME:-privatus-analytics-xp-verify}"
WORK="$ROOT/build/verify"
# Kept out of build/ so a clean build does not throw the download away.
CACHE="$ROOT/.gradle/verify-cache"
BASE="http://localhost:$PORT"

mkdir -p "$CACHE"

cleanup() {
  if [[ "${KEEP:-0}" != "1" ]]; then
    docker rm -f "$NAME" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "==> Building the app and the fixture app in Docker ($JDK_IMAGE)"
docker volume create privatus-analytics-gradle >/dev/null
gradle() {
  docker run --rm -v "$ROOT":/app -v privatus-analytics-gradle:/root/.gradle -w /app "$JDK_IMAGE" \
    ./gradlew --no-daemon -q "$@"
}
gradle clean build
gradle -p tests/fixture-app clean build
mkdir -p "$WORK"

CS_JAR="$CACHE/contentstudio-$CS_VERSION.jar"
if [[ ! -f "$CS_JAR" ]]; then
  echo "==> Downloading Content Studio $CS_VERSION (needed for preview and edit mode)"
  CS_URL="https://repo.enonic.com/public/com/enonic/app/contentstudio/$CS_VERSION/contentstudio-$CS_VERSION.jar"
  curl -fsSL "$CS_URL" -o "$CS_JAR.tmp"
  expected="$(curl -fsSL "$CS_URL.sha1" | cut -c1-40)"
  actual="$(shasum -a 1 "$CS_JAR.tmp" | cut -d' ' -f1)"
  if [[ "$expected" != "$actual" ]]; then
    echo "Content Studio checksum mismatch" >&2
    rm -f "$CS_JAR.tmp"
    exit 1
  fi
  mv "$CS_JAR.tmp" "$CS_JAR"
fi

# A throwaway password for the su user of this test container only.
SU_PASSWORD="$(openssl rand -hex 16)"
SU_HASH="$(printf %s "$SU_PASSWORD" | shasum -a 512 | cut -d' ' -f1)"
printf 'xp.suPassword = {sha512}%s\n' "$SU_HASH" >"$WORK/system.properties"

echo "==> Starting $XP_IMAGE on port $PORT"
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker create --name "$NAME" -p "$PORT:8080" "$XP_IMAGE" >/dev/null
docker cp "$WORK/system.properties" "$NAME:/enonic-xp/home/config/system.properties"
docker cp "$CS_JAR" "$NAME:/enonic-xp/home/deploy/"
docker cp "$ROOT/build/libs/privatus-analytics.jar" "$NAME:/enonic-xp/home/deploy/"
docker cp "$ROOT/tests/fixture-app/build/libs/privatus-analytics-fixture.jar" "$NAME:/enonic-xp/home/deploy/"
docker start "$NAME" >/dev/null

echo "==> Waiting for the fixture sites"
# Logs go to a file first: grep -q on a pipe would stop early and fail the pipe under pipefail.
log_has() {
  docker logs "$NAME" >"$WORK/xp.log" 2>&1
  grep -q "$1" "$WORK/xp.log"
}
for _ in $(seq 1 100); do
  if log_has "Fixture: ready"; then break; fi
  if log_has "Fixture: setup failed"; then
    grep "Fixture:" "$WORK/xp.log" >&2
    exit 1
  fi
  sleep 3
done
log_has "Fixture: ready" || { echo "XP did not get ready" >&2; exit 1; }
for _ in $(seq 1 40); do
  log_has "Started application com.enonic.app.contentstudio" && break
  sleep 3
done

COOKIES="$WORK/cookies.txt"
rm -f "$COOKIES"
curl -fsS -c "$COOKIES" -b "$COOKIES" -H 'Content-Type: application/json' \
  -d "{\"action\":\"login\",\"user\":\"su\",\"password\":\"$SU_PASSWORD\"}" \
  "$BASE/_/idprovider/system" | grep -q '"authenticated":true' || { echo "Login failed" >&2; exit 1; }

PASS=0
FAIL=0
LIVE_PREFIX="/site/privatus-test/master"
CS_PREFIX="/admin/com.enonic.app.contentstudio/site"
FULL_TAG='<script defer src="https://privatusstats.com/js/pa.js" data-site="pa_TEST123" data-modules="engage,auto,vitals,clicks,ask"></script>'

fetch() { # path -> writes $WORK/body and $WORK/headers
  curl -sS -b "$COOKIES" -D "$WORK/headers" -o "$WORK/body" "$BASE$1"
}

head_of() {
  tr -d '\n' <"$WORK/body" | sed -n 's#.*<head>\(.*\)</head>.*#\1#p'
}

result() { # ok? description detail
  if [[ "$1" == "ok" ]]; then
    PASS=$((PASS + 1))
    printf 'PASS  %s\n' "$2"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL  %s\n      %s\n' "$2" "$3"
  fi
}

expect_head() { # description path expected-head
  fetch "$2"
  local got
  got="$(head_of)"
  if [[ "$got" == "$3" ]]; then result ok "$1"; else result no "$1" "head was: $got"; fi
}

expect_no_tag() { # description path
  fetch "$2"
  if grep -q '<head>' "$WORK/body" && ! grep -q 'privatusstats' "$WORK/body"; then
    result ok "$1"
  else
    result no "$1" "body was: $(head -c 400 "$WORK/body")"
  fi
}

expect_header() { # description pattern
  if grep -i '^content-security-policy:' "$WORK/headers" | grep -qF "$2"; then
    result ok "$1"
  else
    result no "$1" "header was: $(grep -i '^content-security-policy:' "$WORK/headers" || echo none)"
  fi
}

echo "==> Checks"
docker logs "$NAME" >"$WORK/xp.log" 2>&1
for site in no-id prefix-only-id invalid-id; do
  if grep -q "Fixture: form rejected $site " "$WORK/xp.log"; then
    result ok "site config form refuses $site"
  else
    result no "site config form refuses $site" "XP saved it as it was"
  fi
done
expect_head "valid site ID, all modules: exact tag in <head>" \
  "$LIVE_PREFIX/valid" "<title>Fixture</title>$FULL_TAG"
expect_head "module fields never saved: all modules, like the form default" \
  "$LIVE_PREFIX/defaults" "<title>Fixture</title>$FULL_TAG"
expect_head "some modules: data-modules lists only the ticked ones, in order" \
  "$LIVE_PREFIX/some-modules" \
  '<title>Fixture</title><script defer src="https://privatusstats.com/js/pa.js" data-site="pa_TEST123" data-modules="engage,vitals,ask"></script>'
expect_head "no modules: empty data-modules, so the tracker loads none" \
  "$LIVE_PREFIX/no-modules" \
  '<title>Fixture</title><script defer src="https://privatusstats.com/js/pa.js" data-site="pa_TEST123" data-modules=""></script>'
expect_no_tag "no site ID: no tag" "$LIVE_PREFIX/no-id"
stored_id_is() { # description expected
  local stored
  stored="$(grep -i '^x-fixture-site-id:' "$WORK/headers" | tr -d '\r' | sed 's/^[^:]*: //')"
  if [[ "$stored" == "$2" ]]; then
    result ok "$1"
  else
    result no "$1" "stored: $(grep -i '^x-fixture-site-id:' "$WORK/headers" || echo none)"
  fi
}
expect_no_tag "site ID with nothing after pa_: no tag" "$LIVE_PREFIX/prefix-only-id"
stored_id_is "the processor really saw pa_" "pa_"
expect_no_tag "invalid site ID (pa_x\" onload=\"alert(1)): no tag" "$LIVE_PREFIX/invalid-id"
stored_id_is "the processor really saw the invalid site ID" 'pa_x" onload="alert(1)'
if grep -q 'onload' "$WORK/body"; then result no "invalid site ID never reaches the page" "found onload"; else result ok "invalid site ID never reaches the page"; fi
expect_no_tag "automatically add script to page off: no tag" "$LIVE_PREFIX/off"
expect_no_tag "preview mode: no tag" "$CS_PREFIX/preview/privatus-test/draft/valid"
grep -q 'mode=preview' "$WORK/body" && result ok "preview URL really ran in preview mode" || result no "preview URL really ran in preview mode" "$(head -c 200 "$WORK/body")"
expect_no_tag "inline mode: no tag" "$CS_PREFIX/inline/privatus-test/draft/valid"
expect_no_tag "edit mode: no tag" "$CS_PREFIX/edit/privatus-test/draft/valid"
grep -q 'mode=edit' "$WORK/body" && result ok "edit URL really ran in edit mode" || result no "edit URL really ran in edit mode" "$(head -c 200 "$WORK/body")"

expect_head "CSP default-src 'self': tag added" "$LIVE_PREFIX/csp-default" "<title>Fixture</title>$FULL_TAG"
expect_header "CSP default-src 'self': tracker host allowed" "default-src 'self' https://privatusstats.com"

fetch "$LIVE_PREFIX/csp-strict"
nonce="$(grep -o 'nonce="[^"]*"' "$WORK/body" | head -1 | sed 's/nonce="\(.*\)"/\1/')"
if [[ -n "$nonce" ]]; then result ok "CSP strict-dynamic: tag gets the request nonce"; else result no "CSP strict-dynamic: tag gets the request nonce" "$(head_of)"; fi
expect_header "CSP strict-dynamic: nonce and host in script-src" "script-src 'strict-dynamic' https://privatusstats.com 'nonce-$nonce'"
expect_header "CSP strict-dynamic: tracker host in connect-src" "connect-src 'self' https://privatusstats.com"

echo
echo "$PASS passed, $FAIL failed"
if [[ "${KEEP:-0}" == "1" ]]; then
  printf '%s\n' "$SU_PASSWORD" >"$WORK/su-password"
  echo "Container $NAME is still running at $BASE (log in as su, password in build/verify/su-password)"
fi
[[ "$FAIL" == "0" ]]
