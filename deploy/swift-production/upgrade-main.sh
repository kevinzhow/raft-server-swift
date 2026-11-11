#!/usr/bin/env bash
# Maintenance-ordered upgrade of the production Main to a staged, verified release.
# Usage: upgrade-main.sh <full-commit>
# Order: pg_dump -> closed-all gateway -> stop unit -> swap manifest+launch spec
# (old copies kept) -> start unit -> private checks -> restore previous gateway.
# Prints rollback instructions on failure. Never prints secrets.
set -euo pipefail
C=${1:?full commit required}
[[ $C =~ ^[0-9a-f]{40}$ ]] || { echo "need full 40-char commit"; exit 2; }
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "$SCRIPT_DIR/env.sh"
swift_production_require DEV_ROOT SOURCE_REPO PRODUCTION_ROOT RELEASE_ROOT_PREFIX \
    BASELINE_COMMIT ARTIFACT_ROOT GATEWAY_FILE GATEWAY_CLOSED_PROFILE \
    GATEWAY_CONTAINER GATEWAY_HEALTH_URL PRIVATE_HEALTH_URL \
    POSTGRES_CONTAINER PRODUCTION_DATABASE SERVICE_UNIT || exit 2
S8=${C:0:8}
PROD=$PRODUCTION_ROOT/production
SUP=$PROD/supervision
A=$ARTIFACT_ROOT/main-$S8-v1
R=$RELEASE_ROOT_PREFIX/$C
G=$GATEWAY_FILE
CLOSED=$GATEWAY_CLOSED_PROFILE
B=$PROD/provision/upgrade-$S8
UNIT=$SERVICE_UNIT
umask 077

[[ -f $A/verify-staged.json ]] || { echo "missing staged verification $A"; exit 2; }
python3 -c "import json,sys;d=json.load(open('$A/verify-staged.json'));sys.exit(0 if d.get('passed') else 1)" || { echo "staged verification not passed"; exit 2; }
mkdir -p -m 700 "$B"

psql_prod() { docker exec $POSTGRES_CONTAINER sh -c "psql -U \"\$POSTGRES_USER\" -d $PRODUCTION_DATABASE -Atc '$1'"; }
state() {
  psql_prod 'select writer_epoch, claimed_at from raft_persistence.writer_control'
  psql_prod 'select domain, aggregate_key, revision, codec_version, md5(payload::text) from raft_persistence.durable_domain_rows order by 1,2'
}

echo "== backup"
state > "$B/pre-upgrade-state.txt"
docker exec "$POSTGRES_CONTAINER" sh -c "pg_dump -U \"\$POSTGRES_USER\" -Fc $PRODUCTION_DATABASE" > "$B/pre-upgrade.pgdump"
sha256sum "$B/pre-upgrade.pgdump" > "$B/pre-upgrade.pgdump.sha256"
ls -la "$B/pre-upgrade.pgdump"

echo "== install release"
if [[ ! -e $R ]]; then cp -a "$A/release" "$R"; fi
chmod -R go-rwx "$R"; chmod 500 "$R/RaftServer"
mkdir -p "$DEV_ROOT/tmp/launchcheck"
cp "$A/main.release.json" "$DEV_ROOT/tmp/launchcheck/main.release.json"
python3 -B - <<EOF
import sys,json,importlib.util
sys.dont_write_bytecode=True
spec=importlib.util.spec_from_file_location('lv','$SUP/launch-verified.py'); lv=importlib.util.module_from_spec(spec); spec.loader.exec_module(lv)
s=json.load(open('$A/main.launch.json')); s['releaseManifest']='$DEV_ROOT/tmp/launchcheck/main.release.json'
print('verify_release OK', lv.verify_release(s)[0])
EOF

OLDSHA=$(python3 -c "import json;print(json.load(open('$SUP/main.launch.json'))['gitCommit'][:8])")
cp -p "$G" "$B/gateway.before.Caddyfile"
cp -p "$SUP/main.launch.json" "$B/main.launch.$OLDSHA.json"
cp -p "$SUP/manifests/main.release.json" "$B/main.release.$OLDSHA.json"

restore_gateway() { cat "$B/gateway.before.Caddyfile" > "$G"; docker restart $GATEWAY_CONTAINER >/dev/null; sleep 4; }
rollback_hint() {
  echo "!! FAILURE. Rollback: cat $B/main.launch.$OLDSHA.json > $SUP/main.launch.json; cat $B/main.release.$OLDSHA.json > $SUP/manifests/main.release.json; systemctl --user restart $UNIT; then restore gateway from $B/gateway.before.Caddyfile"
}
trap rollback_hint ERR

echo "== closed-all"
cat "$CLOSED" > "$G"; docker restart $GATEWAY_CONTAINER >/dev/null; sleep 3
for p in / /api/auth/me; do code=$(curl -s -o /dev/null -w '%{http_code}' $GATEWAY_HEALTH_URL$p); echo "closed $p $code"; [[ $code == 503 ]]; done

echo "== swap"
systemctl --user stop $UNIT
systemctl --user show $UNIT -p Result -p ExecMainStatus
cat "$A/main.release.json" > "$SUP/manifests/main.release.json"
cat "$A/main.launch.json" > "$SUP/main.launch.json"
systemctl --user start $UNIT
for i in $(seq 1 30); do sleep 1; code=$(curl -s -o /dev/null -w '%{http_code}' $PRIVATE_HEALTH_URL/health || true); [[ $code == 200 ]] && break; done
systemctl --user show $UNIT -p ActiveState -p MainPID -p InvocationID
echo "health $code"; [[ $code == 200 ]]
V=$(curl -s $PRIVATE_HEALTH_URL/api/version); echo "$V"
echo "$V" | grep -q "\"sha\":\"$C\""
P=$(systemctl --user show $UNIT -p MainPID --value)
awk '$6 ~ /\.so|RaftServer/ {print $6}' /proc/$P/maps | sort -u | awk -v r="$R" 'index($0,r)==1{s++;next}{o++; print "host:",$0}END{print "staged",s,"other",o}'

echo "== restore gateway"
restore_gateway
sha256sum "$G"
if [[ -n "${PUBLIC_VERSION_URL:-}" ]]; then
  code=$(curl -6 -s -o /dev/null -w '%{http_code}' --max-time 15 "$PUBLIC_VERSION_URL" || true); echo "public /api/version $code"
fi
trap - ERR
sleep 15
state > "$B/post-upgrade-state.txt"
echo "== data diff (domain,key,codec,md5)"
diff <(cut -d'|' -f1,2,4,5 "$B/pre-upgrade-state.txt") <(cut -d'|' -f1,2,4,5 "$B/post-upgrade-state.txt") || true
python3 - <<EOF
import json,datetime
json.dump({"actualObserved":True,"toCommit":"$C","fromCommitShort":"$OLDSHA","mainPID":int("$P"),
 "staged":"$A/verify-staged.json","backup":"$B/pre-upgrade.pgdump","observedAt":datetime.datetime.now(datetime.timezone.utc).isoformat()},
 open("$B/upgrade-record.json","w"),indent=1)
EOF
chmod 600 "$B"/*
echo "UPGRADE OK $C"
