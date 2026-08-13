#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# CTMW ETSA Android takeover bootstrap.
# Public-safe: this file contains no private key or reusable credential.

BUNDLE_NAME="CTMW-ANDROID-TAKEOVER.bundle.tgz"
STATE_ROOT="${HOME}/.ctmw-android-takeover"
PRIVATE_ROOT="${STATE_ROOT}/private"
LOG_ROOT="${STATE_ROOT}/logs"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
SSH="${PREFIX}/bin/ssh"
SSHD="${PREFIX}/bin/sshd"
SSH_KEYGEN="${PREFIX}/bin/ssh-keygen"
SSH_KEYSCAN="${PREFIX}/bin/ssh-keyscan"
TAR="${PREFIX}/bin/tar"
BASE64="${PREFIX}/bin/base64"
SHA256SUM="${PREFIX}/bin/sha256sum"

say() { printf '[CTMW Android takeover] %s\n' "$*"; }
die() { printf '[CTMW Android takeover] ERROR: %s\n' "$*" >&2; exit 1; }

command -v pkg >/dev/null 2>&1 || die 'Termux pkg command not found.'
command -v su >/dev/null 2>&1 || die 'su command not found; this bootstrap is for already-rooted devices.'
su -c 'id -u' 2>/dev/null | grep -qx '0' || die 'Root access is not currently granted to Termux.'

find_bundle() {
    if [ -n "${CTMW_BUNDLE:-}" ] && [ -f "${CTMW_BUNDLE}" ]; then
        printf '%s\n' "${CTMW_BUNDLE}"
        return 0
    fi
    for p in \
        "${HOME}/${BUNDLE_NAME}" \
        "${HOME}/storage/downloads/${BUNDLE_NAME}" \
        "/sdcard/Download/${BUNDLE_NAME}" \
        "/storage/emulated/0/Download/${BUNDLE_NAME}"
    do
        if [ -f "$p" ]; then
            printf '%s\n' "$p"
            return 0
        fi
        if su -c "test -f '$p'" >/dev/null 2>&1; then
            mkdir -p "${STATE_ROOT}"
            su -c "cat '$p'" > "${STATE_ROOT}/${BUNDLE_NAME}"
            chmod 600 "${STATE_ROOT}/${BUNDLE_NAME}"
            printf '%s\n' "${STATE_ROOT}/${BUNDLE_NAME}"
            return 0
        fi
    done
    return 1
}

consume_private_bundle() {
    # The bundle contains a reusable VPS administrator identity and is therefore
    # strictly single-use on the phone. Only consume it after both local and VPS
    # readiness have succeeded so a failed bootstrap remains deliberately retryable.
    rm -f -- "$BUNDLE_PATH" 2>/dev/null || true
    rm -f -- "${HOME}/${BUNDLE_NAME}" "${HOME}/storage/downloads/${BUNDLE_NAME}" 2>/dev/null || true
    for p in \
        "/sdcard/Download/${BUNDLE_NAME}" \
        "/storage/emulated/0/Download/${BUNDLE_NAME}"
    do
        su -c "rm -f '$p'" >/dev/null 2>&1 || true
    done

    for p in "$BUNDLE_PATH" "${HOME}/${BUNDLE_NAME}" "${HOME}/storage/downloads/${BUNDLE_NAME}"; do
        [ ! -f "$p" ] || die "Secret-bearing Android bundle remains after READY: $p"
    done
    for p in \
        "/sdcard/Download/${BUNDLE_NAME}" \
        "/storage/emulated/0/Download/${BUNDLE_NAME}"
    do
        if su -c "test -f '$p'" >/dev/null 2>&1; then
            die "Secret-bearing Android bundle remains after READY: $p"
        fi
    done
}

BUNDLE_PATH="$(find_bundle || true)"
[ -n "$BUNDLE_PATH" ] || die "${BUNDLE_NAME} not found in Termux HOME or Android Download."

say 'Installing required Termux packages automatically...'
pkg install -y openssh coreutils tar >/dev/null

for x in "$SSH" "$SSHD" "$SSH_KEYGEN" "$SSH_KEYSCAN" "$TAR" "$BASE64" "$SHA256SUM"; do
    [ -x "$x" ] || die "Required executable missing after package install: $x"
done

umask 077
mkdir -p "$PRIVATE_ROOT" "$LOG_ROOT"
IMPORT_ROOT="${STATE_ROOT}/.import.$$"
rm -rf "$IMPORT_ROOT"
mkdir -p "$IMPORT_ROOT"
"$TAR" -xzf "$BUNDLE_PATH" -C "$IMPORT_ROOT"

for required in vps_admin_key vps_known_hosts operator_ed25519.pub bundle.env; do
    [ -f "${IMPORT_ROOT}/${required}" ] || die "Bundle is missing ${required}."
done

mv -f "${IMPORT_ROOT}/vps_admin_key" "${PRIVATE_ROOT}/vps_admin_key"
mv -f "${IMPORT_ROOT}/operator_ed25519.pub" "${PRIVATE_ROOT}/operator_ed25519.pub"
mv -f "${IMPORT_ROOT}/vps_known_hosts" "${PRIVATE_ROOT}/vps_known_hosts"
mv -f "${IMPORT_ROOT}/bundle.env" "${PRIVATE_ROOT}/bundle.env"
rm -rf "$IMPORT_ROOT"
chmod 700 "$STATE_ROOT" "$PRIVATE_ROOT" "$LOG_ROOT"
chmod 600 "${PRIVATE_ROOT}/vps_admin_key" "${PRIVATE_ROOT}/vps_known_hosts" "${PRIVATE_ROOT}/bundle.env"
chmod 644 "${PRIVATE_ROOT}/operator_ed25519.pub"

# shellcheck disable=SC1090
. "${PRIVATE_ROOT}/bundle.env"
: "${VPS_HOST:?VPS_HOST missing from bundle}"
: "${VPS_USER:=root}"

TUNNEL_KEY="${PRIVATE_ROOT}/android_tunnel_ed25519"
if [ ! -f "$TUNNEL_KEY" ]; then
    "$SSH_KEYGEN" -q -t ed25519 -N '' -C "ctmw-etsa-android:$(getprop ro.product.model 2>/dev/null || printf device)" -f "$TUNNEL_KEY"
fi
chmod 600 "$TUNNEL_KEY"
chmod 644 "${TUNNEL_KEY}.pub"

HOST_KEY="${PRIVATE_ROOT}/ssh_host_ed25519_key"
if [ ! -f "$HOST_KEY" ]; then
    "$SSH_KEYGEN" -q -t ed25519 -N '' -f "$HOST_KEY"
fi
chmod 600 "$HOST_KEY"
chmod 644 "${HOST_KEY}.pub"

PUB_B64="$("$BASE64" -w 0 < "${TUNNEL_KEY}.pub")"
HOST_PUB_B64="$("$BASE64" -w 0 < "${HOST_KEY}.pub")"
TERMUX_USER_B64="$(printf '%s' "$(id -un)" | "$BASE64" -w 0)"

say 'Enrolling the device tunnel key on the VPS and allocating an isolated Android node...'
ENROLL_RESULT="$($SSH \
    -i "${PRIVATE_ROOT}/vps_admin_key" \
    -o IdentitiesOnly=yes \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="${PRIVATE_ROOT}/vps_known_hosts" \
    -o ConnectTimeout=20 \
    "${VPS_USER}@${VPS_HOST}" \
    bash -s -- "$PUB_B64" "$HOST_PUB_B64" "$TERMUX_USER_B64" <<'CTMW_VPS_ENROLL'
set -euo pipefail
pub_b64="$1"
host_pub_b64="$2"
termux_user_b64="$3"
pub="$(printf '%s' "$pub_b64" | base64 -d)"
host_pub="$(printf '%s' "$host_pub_b64" | base64 -d)"
termux_user="$(printf '%s' "$termux_user_b64" | base64 -d)"
case "$pub" in
    ssh-ed25519\ *) ;;
    *) echo 'ERROR=invalid_public_key'; exit 31 ;;
esac
case "$pub" in
    *$'\n'*|*$'\r'*) echo 'ERROR=multiline_public_key'; exit 32 ;;
esac
case "$host_pub" in
    ssh-ed25519\ *) ;;
    *) echo 'ERROR=invalid_host_public_key'; exit 34 ;;
esac
case "$host_pub" in
    *$'\n'*|*$'\r'*) echo 'ERROR=multiline_host_public_key'; exit 35 ;;
esac
case "$termux_user" in
    ''|*[!A-Za-z0-9._-]*) echo 'ERROR=invalid_termux_user'; exit 36 ;;
esac

umask 077
mkdir -p /root/.ssh
chmod 700 /root/.ssh
ak=/root/.ssh/authorized_keys
touch "$ak"
chmod 600 "$ak"
[ -f "${ak}.ctmw-pre-android" ] || cp -a "$ak" "${ak}.ctmw-pre-android"

digest="$(printf '%s' "$pub" | sha256sum | awk '{print $1}')"
seed_hex="${digest:0:6}"
seed=$((16#$seed_hex))
base=2
span=3651
start=$((base + (seed % span)))

chosen=''
for ((i=0; i<span; i++)); do
    n=$((base + ((start - base + i) % span)))
    port=$((19015 + (10 * n)))
    marker="ctmw-etsa-android:android-node${n}"
    existing="$(grep -F -- "$marker" "$ak" || true)"
    if [ -n "$existing" ]; then
        if printf '%s\n' "$existing" | grep -F -- "$pub" >/dev/null 2>&1; then
            chosen="$n"
            break
        fi
        continue
    fi
    if command -v ss >/dev/null 2>&1 && ss -ltnH "sport = :${port}" 2>/dev/null | grep -q .; then
        continue
    fi
    chosen="$n"
    break
done
[ -n "$chosen" ] || { echo 'ERROR=no_free_android_node'; exit 33; }

n="$chosen"
port=$((19015 + (10 * n)))
marker="ctmw-etsa-android:android-node${n}"
tmp="$(mktemp /root/.ssh/authorized_keys.ctmw.XXXXXX)"
grep -Fv -- "$marker" "$ak" > "$tmp" || true
printf 'restrict,port-forwarding,command="/bin/false",permitlisten="127.0.0.1:%s" %s %s\n' "$port" "$pub" "$marker" >> "$tmp"
chmod 600 "$tmp"
chown root:root "$tmp"
mv -f "$tmp" "$ak"

meta_root=/root/.ctmw-etsa-android
mkdir -p "$meta_root"
chmod 700 "$meta_root"
meta_tmp="$(mktemp "${meta_root}/.${marker}.XXXXXX")"
cat > "$meta_tmp" <<EOF
NODE_INDEX=${n}
NODE_NAME=android-node${n}
CONTROL_PORT=${port}
TUNNEL_KEY_SHA256=${digest}
HOST_KEY_PUB_B64=${host_pub_b64}
TERMUX_USER_B64=${termux_user_b64}
EOF
chmod 600 "$meta_tmp"
mv -f "$meta_tmp" "${meta_root}/android-node${n}.env"

printf 'NODE_INDEX=%s\n' "$n"
printf 'NODE_NAME=android-node%s\n' "$n"
printf 'CONTROL_PORT=%s\n' "$port"
printf 'TUNNEL_KEY_SHA256=%s\n' "$digest"
CTMW_VPS_ENROLL
)"

NODE_INDEX="$(printf '%s\n' "$ENROLL_RESULT" | awk -F= '$1=="NODE_INDEX"{print $2; exit}')"
NODE_NAME="$(printf '%s\n' "$ENROLL_RESULT" | awk -F= '$1=="NODE_NAME"{print $2; exit}')"
CONTROL_PORT="$(printf '%s\n' "$ENROLL_RESULT" | awk -F= '$1=="CONTROL_PORT"{print $2; exit}')"
[ -n "$NODE_INDEX" ] && [ -n "$NODE_NAME" ] && [ -n "$CONTROL_PORT" ] || die "VPS enrollment did not return a complete node contract: ${ENROLL_RESULT}"

LOCAL_PORT=$((22305 + (10 * NODE_INDEX)))
[ "$LOCAL_PORT" -le 65535 ] || die "Allocated local SSH port is out of range: ${LOCAL_PORT}"

AUTHORIZED_KEYS="${PRIVATE_ROOT}/operator_authorized_keys"
cp -f "${PRIVATE_ROOT}/operator_ed25519.pub" "$AUTHORIZED_KEYS"
chmod 600 "$AUTHORIZED_KEYS"

cat > "${STATE_ROOT}/sshd_config" <<EOF
Port ${LOCAL_PORT}
ListenAddress 127.0.0.1
HostKey ${HOST_KEY}
PidFile ${STATE_ROOT}/sshd.pid
AuthorizedKeysFile ${AUTHORIZED_KEYS}
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
PermitEmptyPasswords no
AllowAgentForwarding no
AllowTcpForwarding no
X11Forwarding no
PermitTTY no
StrictModes yes
Subsystem sftp internal-sftp
EOF
chmod 600 "${STATE_ROOT}/sshd_config"

cat > "${STATE_ROOT}/node.env" <<EOF
NODE_INDEX=${NODE_INDEX}
NODE_NAME=${NODE_NAME}
CONTROL_PORT=${CONTROL_PORT}
LOCAL_PORT=${LOCAL_PORT}
VPS_HOST=${VPS_HOST}
VPS_USER=${VPS_USER}
TERMUX_UID=$(id -u)
TERMUX_USER=$(id -un)
PREFIX=${PREFIX}
STATE_ROOT=${STATE_ROOT}
EOF
chmod 600 "${STATE_ROOT}/node.env"

cat > "${STATE_ROOT}/supervisor.sh" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
set -u
STATE_ROOT="${HOME}/.ctmw-android-takeover"
. "${STATE_ROOT}/node.env"
PRIVATE_ROOT="${STATE_ROOT}/private"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
mkdir -p "${STATE_ROOT}/logs"

sshd_loop() {
    while :; do
        "${PREFIX}/bin/sshd" -D -e -f "${STATE_ROOT}/sshd_config" >>"${STATE_ROOT}/logs/sshd.log" 2>&1
        sleep 2
    done
}

tunnel_loop() {
    while :; do
        "${PREFIX}/bin/ssh" -NT \
            -i "${PRIVATE_ROOT}/android_tunnel_ed25519" \
            -o IdentitiesOnly=yes \
            -o BatchMode=yes \
            -o ExitOnForwardFailure=yes \
            -o StrictHostKeyChecking=yes \
            -o UserKnownHostsFile="${PRIVATE_ROOT}/vps_known_hosts" \
            -o ServerAliveInterval=30 \
            -o ServerAliveCountMax=3 \
            -o ConnectTimeout=20 \
            -R "127.0.0.1:${CONTROL_PORT}:127.0.0.1:${LOCAL_PORT}" \
            "${VPS_USER}@${VPS_HOST}" >>"${STATE_ROOT}/logs/tunnel.log" 2>&1
        sleep 3
    done
}

printf '%s\n' "$$" > "${STATE_ROOT}/supervisor.pid"
trap 'rm -f "${STATE_ROOT}/supervisor.pid"; kill 0 2>/dev/null || true' EXIT INT TERM
sshd_loop &
tunnel_loop &
wait
EOF
chmod 700 "${STATE_ROOT}/supervisor.sh"

cat > "${STATE_ROOT}/launch.sh" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
STATE_ROOT="${HOME}/.ctmw-android-takeover"
pidfile="${STATE_ROOT}/supervisor.pid"
if [ -f "$pidfile" ]; then
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        exit 0
    fi
    rm -f "$pidfile"
fi
nohup "${STATE_ROOT}/supervisor.sh" >/dev/null 2>&1 &
EOF
chmod 700 "${STATE_ROOT}/launch.sh"

"${STATE_ROOT}/launch.sh"

PERSISTENCE='termux-session'
REBOOT_PERSISTENT=false
SERVICE_D='/data/adb/service.d'
if su -c "test -d '${SERVICE_D}' && test -w '${SERVICE_D}'" >/dev/null 2>&1; then
    SU_BIN="$(command -v su)"
    TERMUX_HOME="${HOME}"
    TERMUX_UID="$(id -u)"
    BOOT_LOCAL="${STATE_ROOT}/ctmw-etsa-android-boot.sh"
    cat > "$BOOT_LOCAL" <<EOF
#!/system/bin/sh
sleep 20
'${SU_BIN}' -s '${PREFIX}/bin/sh' -c 'HOME=${TERMUX_HOME} PREFIX=${PREFIX} ${STATE_ROOT}/launch.sh' ${TERMUX_UID} >/dev/null 2>&1 &
exit 0
EOF
    chmod 700 "$BOOT_LOCAL"
    su -c "cp '$BOOT_LOCAL' '${SERVICE_D}/ctmw-etsa-${NODE_NAME}.sh' && chmod 755 '${SERVICE_D}/ctmw-etsa-${NODE_NAME}.sh'"
    PERSISTENCE='root-service.d'
    REBOOT_PERSISTENT=true
fi

say 'Waiting for the dedicated localhost-only SSH endpoint...'
LOCAL_READY=0
for _ in $(seq 1 40); do
    if "$SSH_KEYSCAN" -T 2 -p "$LOCAL_PORT" 127.0.0.1 2>/dev/null | grep -q '^\[127\.0\.0\.1\]'; then
        LOCAL_READY=1
        break
    fi
    sleep 1
done
[ "$LOCAL_READY" -eq 1 ] || die 'Dedicated Android SSH endpoint did not become READY.'

say 'Waiting for the VPS loopback reverse-tunnel listener...'
REMOTE_READY=0
for _ in $(seq 1 40); do
    if "$SSH" \
        -i "${PRIVATE_ROOT}/vps_admin_key" \
        -o IdentitiesOnly=yes \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=yes \
        -o UserKnownHostsFile="${PRIVATE_ROOT}/vps_known_hosts" \
        -o ConnectTimeout=5 \
        "${VPS_USER}@${VPS_HOST}" \
        "ss -ltnH 'sport = :${CONTROL_PORT}' 2>/dev/null | grep -q '127.0.0.1:${CONTROL_PORT}'" >/dev/null 2>&1; then
        REMOTE_READY=1
        break
    fi
    sleep 1
done
[ "$REMOTE_READY" -eq 1 ] || die 'VPS reverse-tunnel listener did not become READY.'

# The reusable VPS administrator key is needed only for initial enrollment and
# READY verification. Do not retain either the administrator key or the
# consumed single-use bundle on the phone after READY succeeds.
rm -f "${PRIVATE_ROOT}/vps_admin_key"
consume_private_bundle

cat > "${STATE_ROOT}/ready.env" <<EOF
STATUS=READY
NODE_INDEX=${NODE_INDEX}
NODE_NAME=${NODE_NAME}
TARGET_SSH=127.0.0.1:${LOCAL_PORT}
VPS_CONTROL=127.0.0.1:${CONTROL_PORT}
VPS_HOST=${VPS_HOST}
PERSISTENCE=${PERSISTENCE}
REBOOT_PERSISTENT=${REBOOT_PERSISTENT}
ROOT_LOGIN_DEFAULT=false
PASSWORD_AUTH=false
VPS_ADMIN_KEY_RETAINED=false
OPERATOR_PRIVATE_KEY_ON_PHONE=false
PRIVATE_BUNDLE_CONSUMED=true
EOF
chmod 600 "${STATE_ROOT}/ready.env"

printf '\n============================================================\n'
printf ' ANDROID REMOTE TAKEOVER READY\n'
printf '============================================================\n'
printf 'Node              : %s (%s)\n' "$NODE_NAME" "$NODE_INDEX"
printf 'Termux user       : %s\n' "$(id -un)"
printf 'Target SSH        : 127.0.0.1:%s (localhost only)\n' "$LOCAL_PORT"
printf 'VPS control       : 127.0.0.1:%s\n' "$CONTROL_PORT"
printf 'Route             : VPS 127.0.0.1:%s -> Android 127.0.0.1:%s\n' "$CONTROL_PORT" "$LOCAL_PORT"
printf 'Persistence       : %s\n' "$PERSISTENCE"
printf 'Reboot persistent : %s\n' "$REBOOT_PERSISTENT"
printf 'Password auth     : disabled\n'
printf 'Default SSH root  : disabled (explicit su only)\n'
printf 'Operator key      : public key only on phone\n'
printf 'VPS admin key     : removed from Termux state after READY\n'
printf 'Bundle            : local-only; consumed after READY\n'
printf '============================================================\n'

