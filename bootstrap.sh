#!/bin/sh
# bootstrap.sh — a fresh Debian box to a running streaming node in one line.
#
#   curl -fsSL https://raw.githubusercontent.com/garjones/curling-streamer/main/bootstrap.sh \
#     | sudo sh -s -- --club <owner>/<site-repo> --sheets 1-6
#
# It asks for ONE thing: the club machine key, an SSH private key kept in
# the club's password manager. That key reads the club's private site repo
# and decrypts its secrets.env.age; everything else is fetched. Re-running
# it is the upgrade path: it pulls both repos and re-applies the config.
#
#   --club owner/repo   the club's private site repo on GitHub (required)
#   --sheets 1-6        the sheets THIS box carries (required)
#   --key-file PATH     the machine key, instead of pasting it
#   --branch NAME       product branch to install (default main)
#   --no-enable         install and configure, but do not start any unit
#
# Debian stable amd64 only. Everything it does is idempotent.

set -eu

PRODUCT_REPO="${PRODUCT_REPO:-https://github.com/garjones/curling-streamer.git}"
PRODUCT_DIR=/opt/curling-streamer
CLUB_DIR=/opt/curling-club
ETC=/etc/streamer
KEY="$ETC/machine.key"
BRANCH=main
CLUB=""
SHEETS=""
KEYFILE=""
DEPLOY_OPTS=""

die() { echo "bootstrap: $*" >&2; exit 1; }
usage() { sed -n '2,18p' "$0" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --club)      CLUB=$2; shift 2;;
        --sheets)    SHEETS=$2; shift 2;;
        --key-file)  KEYFILE=$2; shift 2;;
        --branch)    BRANCH=$2; shift 2;;
        --no-enable) DEPLOY_OPTS="--no-enable"; shift;;
        *)           usage;;
    esac
done
[ -n "$CLUB" ] && [ -n "$SHEETS" ] || usage
case "$CLUB" in */*) ;; *) die "--club must be owner/repo, e.g. yourclub/curling-yourclub";; esac
[ "$(id -u)" = 0 ] || die "run as root (sudo)"
command -v apt-get >/dev/null 2>&1 || die "this installer is for Debian/Ubuntu"

echo "== packages"
apt-get update -qq
apt-get install -y -qq --no-install-recommends git age ca-certificates curl openssh-client

echo "== product: $PRODUCT_REPO ($BRANCH) -> $PRODUCT_DIR"
if [ -d "$PRODUCT_DIR/.git" ]; then
    git -C "$PRODUCT_DIR" fetch -q origin "$BRANCH"
    git -C "$PRODUCT_DIR" checkout -q "$BRANCH"
    git -C "$PRODUCT_DIR" pull -q --ff-only origin "$BRANCH"
else
    git clone -q -b "$BRANCH" "$PRODUCT_REPO" "$PRODUCT_DIR"
fi
sh "$PRODUCT_DIR/install.sh"

echo "== club machine key"
install -d -m 755 "$ETC"
if [ ! -f "$KEY" ]; then
    if [ -n "$KEYFILE" ]; then
        install -m 600 "$KEYFILE" "$KEY"
    else
        [ -r /dev/tty ] || die "no terminal to paste the key on — use --key-file PATH"
        printf '\nPaste the club machine key from the password manager\n' > /dev/tty
        printf '(the whole block, -----BEGIN ... -----END), then press Enter:\n\n' > /dev/tty
        umask 077
        : > "$KEY"
        while IFS= read -r line; do
            printf '%s\n' "$line" >> "$KEY"
            case "$line" in *-----END*) break;; esac
        done < /dev/tty
        umask 022
    fi
    if ! ssh-keygen -y -f "$KEY" >/dev/null 2>&1; then
        rm -f "$KEY"
        die "that is not a usable private key — nothing was saved; run again"
    fi
    echo "machine key installed at $KEY (mode 600)"
else
    echo "machine key already at $KEY"
fi

echo "== club repo: $CLUB -> $CLUB_DIR"
SSH_CMD="ssh -i $KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
if [ -d "$CLUB_DIR/.git" ]; then
    git -C "$CLUB_DIR" pull -q --ff-only
else
    GIT_SSH_COMMAND="$SSH_CMD" git clone -q "git@github.com:$CLUB.git" "$CLUB_DIR" || \
        die "could not clone git@github.com:$CLUB.git — is the machine key added as a deploy key on that repo?"
    git -C "$CLUB_DIR" config core.sshCommand "$SSH_CMD"   # so a plain 'git pull' works later
fi

echo "== apply"
# shellcheck disable=SC2086
streamer-deploy "$CLUB_DIR" --sheets "$SHEETS" --key "$KEY" $DEPLOY_OPTS

cat <<DONE

== done. Next time (upgrade or config change), the same one line does it all;
   or on the box:  cd $CLUB_DIR && git pull && streamer-deploy . --sheets $SHEETS
DONE
