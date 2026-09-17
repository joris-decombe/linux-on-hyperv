#!/bin/bash
#
# linux-on-hyperv: guest side.
#
# Run this inside a freshly installed Fedora Workstation running as a Hyper-V
# guest. It turns on the guest's own RDP server so the desktop -- picture,
# sound, clipboard, and a resolution that follows the window -- arrives on
# Windows through the Remote Desktop client you already have.
#
# Everything here is idempotent. Re-running it is the supported way to repair a
# half-finished run.

set -o pipefail

LH_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=lib/common.sh
source "$LH_ROOT/lib/common.sh"
for module in desktop preflight integration remote-desktop audio firewall; do
  # shellcheck disable=SC1090
  source "$LH_ROOT/lib/$module.sh"
done

LH_MODULES=(integration remote_desktop audio firewall)

usage() {
  cat <<USAGE
Usage: sudo bash setup.sh [options]

Options:
  --desktop NAME  gnome | kde | xfce | cinnamon | mate | auto (default: auto).
                  Only gnome gives a session sized by the connecting client;
                  see lib/desktop.sh for what each backend can and cannot do.
  --port N        RDP port (default: ${LH_RDP_PORT}).
  --only MODULE   Run just one module. Repeatable.
  --skip MODULE   Skip a module. Repeatable.
  --dry-run       Print what would change without changing anything.
  -h, --help      This.

Modules: ${LH_MODULES[*]}
USAGE
}

only=()
skip=()

while [[ $# -gt 0 ]]; do
  case $1 in
  --desktop)
    LH_DESKTOP=${2:?--desktop needs a name}
    shift 2
    ;;
  --port)
    LH_RDP_PORT=${2:?--port needs a number}
    shift 2
    ;;
  --only)
    only+=("${2:?--only needs a module name}")
    shift 2
    ;;
  --skip)
    skip+=("${2:?--skip needs a module name}")
    shift 2
    ;;
  --dry-run)
    LH_DRY_RUN=1
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    printf 'unknown option: %s\n\n' "$1" >&2
    usage >&2
    exit 2
    ;;
  esac
done

# Validate the desktop name here rather than letting it fail deep in dispatch,
# after packages have already been installed.
case ${LH_DESKTOP:-auto} in
auto | gnome | kde | xfce | cinnamon | mate) ;;
*) die "unknown desktop '${LH_DESKTOP}'. Known: gnome kde xfce cinnamon mate auto" ;;
esac

for name in "${only[@]}" "${skip[@]}"; do
  [[ " ${LH_MODULES[*]} " == *" $name "* ]] || die "unknown module '$name'. Known: ${LH_MODULES[*]}"
done

should_run() {
  local name=$1
  if [[ ${#only[@]} -gt 0 ]]; then
    [[ " ${only[*]} " == *" $name "* ]]
    return
  fi
  [[ " ${skip[*]} " != *" $name "* ]]
}

[[ $LH_DRY_RUN == 1 ]] && printf '\033[33mDry run: nothing will be changed.\033[0m\n'

lh_preflight

for name in "${LH_MODULES[@]}"; do
  should_run "$name" || {
    note "skipping $name"
    continue
  }
  "lh_$name"
done

address=$(lh_primary_address)

cat <<DONE

$(printf '\033[36mDone.\033[0m')

  This guest is at ${address:-<no address yet>}.

  On Windows, from this repo's windows/ directory:
      Import-Module .\HyperVLinux.psd1
      Start-LinuxDesktop

  Desktop: ${LH_DESKTOP}, backend: $(lh_rdp_backend).
$(if [[ $(lh_rdp_backend) == gnome ]]; then
    printf '%s
' "  RDP asks for credentials first, then GDM asks again. Both are this guest's"       "  own username and password - the unattended install sets the RDP pair to"       "  match, so it is one secret, not two."       ""       "  Resize the window and the desktop resizes with it. Sound plays on Windows."
  else
    printf '%s
' "  This backend does not resize with the client window - only the GNOME"       "  backend does. See the notes printed above for what it needs."
  fi)
  The Hyper-V console still works as a silent fallback.

  Something wrong? Run: sudo bash $LH_ROOT/doctor.sh
DONE
