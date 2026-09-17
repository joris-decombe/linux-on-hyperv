#!/bin/bash
#
# Reports the state of every piece setup.sh configures, and says what to do
# about each one that is wrong. Read-only: it changes nothing, and it never
# blocks on a password prompt.

set -o pipefail
LH_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$LH_ROOT/lib/common.sh"
source "$LH_ROOT/lib/desktop.sh"
lh_detect_distro
lh_detect_desktop >/dev/null 2>&1 || LH_DESKTOP=unknown

fails=0

check() {
  local label=$1 fix=$2
  shift 2
  if "$@" >/dev/null 2>&1; then
    printf '  \033[32mok  \033[0m %s\n' "$label"
  else
    printf '  \033[31mbad \033[0m %s\n' "$label"
    printf '        \033[90m%s\033[0m\n' "$fix"
    fails=$((fails + 1))
  fi
}

step 'Host and guest'
printf '    virt:    %s\n' "$(systemd-detect-virt 2>/dev/null || echo unknown)"
printf '    distro:  %s\n' "$(. /etc/os-release 2>/dev/null && printf '%s' "$PRETTY_NAME")"
printf '    gnome:   %s\n' "$(gnome-shell --version 2>/dev/null || echo 'not installed')"
printf '    address: %s\n' "$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | head -1)"

step 'Hyper-V integration'
check 'hypervkvpd active (host can see the guest IP)' \
  'sudo systemctl enable --now hypervkvpd.service' \
  systemctl is-active --quiet hypervkvpd.service

step 'Remote desktop'
case $(lh_rdp_backend) in
gnome)
  check 'gnome-remote-desktop installed'     'sudo bash setup.sh --only remote_desktop'     bash -c 'command -v grdctl >/dev/null'
  check 'TLS certificate present'     'sudo bash setup.sh --only remote_desktop'     test -f /var/lib/gnome-remote-desktop/certificates/rdp-tls.crt
  check 'system RDP enabled in grdctl'     'sudo grdctl --system rdp enable'     bash -c 'grdctl --system status 2>/dev/null | grep -qi enabled'
  # Empty credentials are the failure that looks like success: the daemon
  # starts, logs "RDP server started", holds port 3389 open, and then denies
  # every client with "Credentials are not set". Nothing outside the journal
  # says anything is wrong, so check it explicitly.
  check 'RDP credentials set'     'sudo grdctl --system rdp set-credentials <user>'     bash -c 'grdctl --system status 2>/dev/null | grep -qiE "^[[:space:]]*Username:[[:space:]]*\(empty\)" && exit 1 || exit 0'
  check 'gnome-remote-desktop.service active'     'sudo systemctl enable --now gnome-remote-desktop.service  (then: journalctl -u gnome-remote-desktop -n 50)'     systemctl is-active --quiet gnome-remote-desktop.service
  ;;
kde)
  check 'krdp installed'     'sudo bash setup.sh --only remote_desktop'     bash -c 'command -v krdpserver >/dev/null'
  printf '    KRdp is enabled per-user in System Settings, not by this script,
'
  printf '    and cannot do headless login - see lib/desktop.sh.
'
  ;;
xrdp)
  check 'xrdp.service active'     'sudo systemctl enable --now xrdp'     systemctl is-active --quiet xrdp.service
  check '.xsession written for the session user'     'sudo bash setup.sh --only remote_desktop'     bash -c 'test -f "$(getent passwd "${SUDO_USER:-$(id -un)}" | cut -d: -f6)/.xsession"'
  ;;
*)
  printf '    no backend for this desktop
'
  ;;
esac
check "listening on ${LH_RDP_PORT:-3389}"   'The service is up but not bound. Check its journal.'   bash -c "ss -tlnH \"sport = :${LH_RDP_PORT:-3389}\" 2>/dev/null | grep -q ."

step 'Audio'
check 'pipewire installed' \
  'sudo dnf install pipewire wireplumber' \
  rpm -q pipewire
printf '    RDP sessions get their own sink from gnome-remote-desktop;\n'
printf '    a missing sink on the console is normal and not a fault.\n'

step 'Firewall'
if has firewall-cmd && systemctl is-active --quiet firewalld 2>/dev/null; then
  # A diagnostic must never block on a password prompt.
  if ! sudo -n true 2>/dev/null; then
    printf '    firewalld rules need sudo to read; re-run after a "sudo -v"\n'
  elif sudo -n firewall-cmd --list-all 2>/dev/null | grep -q '3389\|rdp'; then
    printf '  \033[32mok  \033[0m RDP allowed\n'
  else
    printf '  \033[31mbad \033[0m no RDP rule in firewalld\n'
    printf '        \033[90mRe-run: sudo bash setup.sh --only firewall\033[0m\n'
    fails=$((fails + 1))
  fi
else
  printf '    firewalld not running; nothing to check\n'
fi

printf '\n'
if [[ $fails -eq 0 ]]; then
  printf '\033[32mAll checks passed.\033[0m\n'
else
  printf '\033[31m%d check(s) failed.\033[0m See the fix under each.\n' "$fails"
  exit 1
fi
