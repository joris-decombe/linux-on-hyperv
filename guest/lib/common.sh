# Shared helpers for the guest kit. Sourced, never executed.

set -o pipefail

LH_DRY_RUN=${LH_DRY_RUN:-0}
LH_STAMP="# Managed by linux-on-hyperv. Re-running setup.sh overwrites this."

step() { printf '\n\033[36m==> %s\033[0m\n' "$*"; }
ok() { printf '  \033[32m+\033[0m %s\n' "$*"; }
note() { printf '    \033[90m%s\033[0m\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*" >&2; }
die() {
  printf '\n\033[31mfailed:\033[0m %s\n' "$*" >&2
  exit 1
}

# Every side effect goes through run(), so --dry-run is honest rather than
# approximate.
run() {
  if [[ $LH_DRY_RUN == 1 ]]; then
    printf '    \033[90m[dry-run] %s\033[0m\n' "$*"
    return 0
  fi
  "$@"
}

# Writes a file from stdin, skipping the write when the content already
# matches. Sets LH_WROTE=1 when it actually changed something.
write_file() {
  local path=$1
  local content
  content=$(cat)
  LH_WROTE=0

  if [[ -f $path ]] && [[ $(cat "$path" 2>/dev/null) == "$content" ]]; then
    note "unchanged: $path"
    return 0
  fi

  if [[ $LH_DRY_RUN == 1 ]]; then
    printf '    \033[90m[dry-run] write %s (%d bytes)\033[0m\n' "$path" "${#content}"
    return 0
  fi

  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$content" >"$path"
  LH_WROTE=1
  ok "wrote $path"
}

has() { command -v "$1" >/dev/null 2>&1; }

# --- distro abstraction -------------------------------------------------
#
# The point of this kit is now to compare desktops, which means it has to
# install packages on whichever base the desktop ships best on. Everything
# distro-specific funnels through here rather than being sprinkled around.

# Sets LH_DISTRO (the ID from os-release) and LH_PKG (the package manager).
lh_detect_distro() {
  local id id_like
  id=$(. /etc/os-release 2>/dev/null && printf '%s' "${ID:-}")
  id_like=$(. /etc/os-release 2>/dev/null && printf '%s' "${ID_LIKE:-}")
  LH_DISTRO=${id:-unknown}

  case "$id $id_like" in
  *fedora* | *rhel* | *centos*) LH_PKG=dnf ;;
  *debian* | *ubuntu*) LH_PKG=apt ;;
  *suse*) LH_PKG=zypper ;;
  *) LH_PKG="" ;;
  esac
}

pkg_installed() {
  case $LH_PKG in
  dnf) rpm -q "$1" >/dev/null 2>&1 ;;
  apt) dpkg -s "$1" >/dev/null 2>&1 ;;
  zypper) rpm -q "$1" >/dev/null 2>&1 ;;
  *) return 1 ;;
  esac
}

# Installs only what is missing, so re-runs are quiet and fast.
pkg_install() {
  local missing=()
  local pkg
  for pkg in "$@"; do
    [[ -n $pkg ]] || continue
    pkg_installed "$pkg" || missing+=("$pkg")
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    note "already installed: $*"
    return 0
  fi

  case $LH_PKG in
  dnf) run dnf install -y "${missing[@]}" ;;
  apt)
    run apt-get update -qq
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
    ;;
  zypper) run zypper --non-interactive install "${missing[@]}" ;;
  *) die "unknown package manager; install these by hand: ${missing[*]}" ;;
  esac || die "package install failed for: ${missing[*]}"

  ok "installed: ${missing[*]}"
}

enable_unit() {
  local unit=$1
  if systemctl is-enabled --quiet "$unit" 2>/dev/null && systemctl is-active --quiet "$unit" 2>/dev/null; then
    note "already enabled and running: $unit"
    return 0
  fi
  run systemctl enable --now "$unit" || warn "could not enable $unit"
}

# The invoking user, even though the script runs under sudo. Almost everything
# here is system-level, but the RDP login is per-user and needs the real name.
#
# SUDO_USER is empty when this runs from the first-boot unit, where there is no
# invoking user at all -- systemd started it as root. Falling back to `id -un`
# there yields "root", which would have configured autologin and the RDP login
# for an account nobody uses. So fall back to the first ordinary account
# instead: UID >= 1000 with a real shell, which on these machines is the
# account the kickstart created.
target_user() {
  if [[ -n ${SUDO_USER:-} ]]; then
    printf '%s' "$SUDO_USER"
    return
  fi
  local user
  user=$(awk -F: '$3 >= 1000 && $3 < 65534 && $7 !~ /(nologin|false)$/ { print $1; exit }' /etc/passwd)
  printf '%s' "${user:-$(id -un)}"
}
