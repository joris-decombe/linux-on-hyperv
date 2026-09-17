# Refuses to run anywhere this kit would do the wrong thing.

lh_preflight() {
  step 'Preflight'

  [[ $EUID -eq 0 ]] || die 'Run this with sudo: sudo bash guest/setup.sh'
  [[ -n ${SUDO_USER:-} ]] || warn 'No SUDO_USER, so falling back to the first ordinary account (see target_user).'

  lh_detect_distro
  [[ -n $LH_PKG ]] || die "Unsupported distribution '$LH_DISTRO'. Known package managers: dnf, apt, zypper."
  ok "$(. /etc/os-release 2>/dev/null && printf '%s' "$PRETTY_NAME") (${LH_PKG})"

  lh_detect_desktop

  # Only the GNOME backend is version-gated, and sharply: headless Remote Login
  # -- a full session with a virtual monitor sized by the client -- arrived in
  # GNOME 46. Below that you get screen sharing of an existing local session,
  # which cannot resize and needs someone logged in at the console first.
  if [[ $LH_DESKTOP == gnome ]]; then
    local version major
    version=$(gnome-shell --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)
    major=${version%%.*}
    if [[ -n $major ]] && ((major >= 46)); then
      ok "GNOME $version (headless Remote Login supported)"
    else
      warn "GNOME ${version:-unknown} is older than 46; headless Remote Login is unavailable."
      note 'You will get screen sharing of the console session instead, without dynamic resolution.'
    fi
  fi

  local virt
  virt=$(systemd-detect-virt 2>/dev/null || echo none)
  case $virt in
  microsoft) ok 'Running under Hyper-V' ;;
  none) die 'Not running in a VM. This kit configures a guest for a Windows host.' ;;
  *) warn "Detected '$virt', not Hyper-V. The RDP parts still apply; the integration services do not." ;;
  esac
}
