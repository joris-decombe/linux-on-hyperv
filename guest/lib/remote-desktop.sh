# Remote desktop: dispatches to whichever backend the chosen desktop supports.
#
# These are not equivalent. See lib/desktop.sh for the reasoning; the short
# version is that only the GNOME backend gives a session whose monitor is
# sized by the connecting client, which is what makes the window resizable.

LH_TLS_DIR=/var/lib/gnome-remote-desktop/certificates
LH_RDP_PORT=${LH_RDP_PORT:-3389}

lh_remote_desktop() {
  local backend
  backend=$(lh_rdp_backend)
  [[ -n $backend ]] || die "no remote-desktop backend known for desktop '$LH_DESKTOP'"

  step "Remote desktop (backend: $backend)"
  "lh_rdp_$backend"
}

# --- shared ---------------------------------------------------------------

# A self-signed certificate is fine here: the connection is host-to-guest, and
# the .rdp profile written by Start-LinuxDesktop tells mstsc not to fail on an
# untrusted issuer. It is still real TLS on the wire.
lh_make_cert() {
  local dir=$1 owner=${2:-}
  local key="$dir/rdp-tls.key" crt="$dir/rdp-tls.crt"

  if [[ -f $key && -f $crt ]]; then
    note 'TLS certificate already present'
    return 0
  fi

  has openssl || pkg_install "$(lh_packages openssl)"

  run mkdir -p "$dir"
  run openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
    -subj "/C=NZ/ST=NA/L=NA/O=linux-on-hyperv/CN=$(uname -n)" \
    -out "$crt" -keyout "$key" 2>/dev/null || die 'could not generate the RDP TLS certificate'

  [[ -n $owner ]] && run chown -R "$owner" "$dir" 2>/dev/null
  run chmod 600 "$key"
  [[ $LH_DRY_RUN == 1 ]] || ok "generated $crt"
}

# --- GNOME ----------------------------------------------------------------

lh_rdp_gnome() {
  pkg_install "$(lh_packages grd)"
  lh_make_cert "$LH_TLS_DIR" gnome-remote-desktop:gnome-remote-desktop

  has grdctl || die 'grdctl not found even though gnome-remote-desktop is installed.'

  # --system is Remote Login: a system service that puts GDM on the far end,
  # creating a session on demand with a virtual monitor sized by the client.
  # The per-user service is a different thing and is deliberately left alone.
  run grdctl --system rdp set-tls-cert "$LH_TLS_DIR/rdp-tls.crt"
  run grdctl --system rdp set-tls-key "$LH_TLS_DIR/rdp-tls.key"
  run grdctl --system rdp enable
  lh_rdp_credentials
  enable_unit gnome-remote-desktop.service

  if [[ $LH_DRY_RUN != 1 ]]; then
    printf '\n'
    grdctl --system status 2>/dev/null || warn 'grdctl --system status failed'
  fi

  ok 'Remote Login enabled'
}

# The daemon will not talk to a client until these are set.
#
# This cost an evening. Remote Login looks like it should authenticate against
# PAM -- it ends at a GDM login screen, after all -- so it is easy to assume the
# account's own password is enough and that setting credentials is only for the
# per-user "Desktop Sharing" mode. It is not. With them empty the daemon starts
# cleanly, logs "RDP server started", accepts the TCP connection, and then
# refuses to negotiate, logging:
#
#     [RDP] Credentials are not set, denying client
#
# The client shows 0x904 with no explanation, and a port scan shows 3389 open,
# so everything outside the journal says the server is fine.
#
# The credentials are a gate in front of the daemon, separate from the login
# you then do at GDM. We set them to the same account password, which keeps it
# to one secret; LH_RDP_CREDENTIALS_FILE is how the unattended install passes
# it in (see New-KickstartContent -RdpPassword).
lh_rdp_credentials() {
  local file=${LH_RDP_CREDENTIALS_FILE:-/var/lib/linux-on-hyperv/rdp-credentials}
  local user password

  if [[ ! -f $file ]]; then
    warn 'no RDP credentials supplied, so the daemon will deny every client'
    note 'Set them by hand with:  sudo grdctl --system rdp set-credentials <user>'
    note "or drop a file at $file with 'user' and 'password' lines."
    return 0
  fi

  # shellcheck disable=SC1090
  user=$(sed -n 's/^user=//p' "$file")
  password=$(sed -n 's/^password=//p' "$file")
  if [[ -z $user || -z $password ]]; then
    warn "$file has no user= or password= line; leaving credentials unset"
    return 0
  fi

  if [[ $LH_DRY_RUN == 1 ]]; then
    note "[dry-run] grdctl --system rdp set-credentials $user <password>"
    return 0
  fi

  # The password goes on grdctl's stdin rather than its argv: argv is world
  # readable in /proc for as long as the process lives. Twice, because it
  # prompts for the password and then for a confirmation.
  if printf '%s\n%s\n' "$password" "$password" |
    grdctl --system rdp set-credentials "$user" 2>/dev/null; then
    ok "RDP credentials set for '$user'"
  elif grdctl --system rdp set-credentials "$user" "$password" 2>/dev/null; then
    # Older grdctl takes the password as an argument and cannot prompt.
    ok "RDP credentials set for '$user' (argv form)"
  else
    warn 'could not set RDP credentials; the daemon will deny clients'
    return 0
  fi

  # Prove it took. "Password: (empty)" in the status output is exactly the
  # state that produced the silent failure, so refusing to claim success
  # without checking is the whole point.
  if grdctl --system status 2>/dev/null | grep -qiE '^\s*Username:\s*\(empty\)'; then
    warn 'grdctl still reports an empty username; credentials did not take'
  fi

  # The daemon reads its credentials once, at startup, and by now it is
  # already running -- the grdctl calls above activate it over D-Bus. So
  # enable_unit later finds it "already enabled and running" and leaves it
  # alone, and it keeps denying every client from a credential store that has
  # since been filled in. The journal says "Credentials are not set" while
  # grdctl --system status shows them set, which is as contradictory as it
  # sounds and took a second full rebuild to see.
  if systemctl is-active --quiet gnome-remote-desktop.service; then
    run systemctl restart gnome-remote-desktop.service ||
      warn 'could not restart gnome-remote-desktop; it may still be using empty credentials'
  fi
}

# --- KDE ------------------------------------------------------------------

lh_rdp_kde() {
  pkg_install "$(lh_packages krdp)"

  warn 'KRdp cannot do headless login.'
  note 'It attaches to a session that is already running, so something has to be'
  note 'hosting one -- here, the Hyper-V console session. Consequences:'
  note '  * the resolution follows that session, not your RDP window, so'
  note '    resizing scales rather than reflows;'
  note '  * you must be logged in at the console before connecting.'
  note 'Audio and clipboard do work. This backend is here for comparison.'

  lh_make_cert /var/lib/krdp

  # KRdp is configured per-user through System Settings and stores its password
  # in KWallet, which is not scriptable from a root shell in any honest way.
  note ''
  note 'Finish in the guest, as your user:'
  note '  System Settings -> Remote Desktop -> enable, set a username/password'
  note 'or: krdpserver --port '"$LH_RDP_PORT"' --username <u> --password <p>'
}

# --- xrdp (X11 desktops) --------------------------------------------------

lh_rdp_xrdp() {
  pkg_install "$(lh_packages xrdp)"

  # xrdp starts its own X server via xorgxrdp, so it is unaffected by display
  # managers dropping X11 -- but it cannot serve a Wayland-only desktop, which
  # is why this backend is only offered for XFCE/Cinnamon/MATE.
  local session
  case $LH_DESKTOP in
  xfce) session='startxfce4' ;;
  cinnamon) session='cinnamon-session' ;;
  mate) session='mate-session' ;;
  *) die "xrdp backend does not know how to start '$LH_DESKTOP'" ;;
  esac

  # xrdp reads ~/.xsession for what to launch. Write it for the real user, not
  # for root, or every RDP login lands in a grey void with no window manager.
  local user home
  user=$(target_user)
  home=$(getent passwd "$user" | cut -d: -f6)
  if [[ -n $home && -d $home ]]; then
    write_file "$home/.xsession" <<XSESSION
$LH_STAMP
exec $session
XSESSION
    [[ $LH_DRY_RUN == 1 ]] || run chown "$user:$user" "$home/.xsession"
  else
    warn "could not resolve a home directory for $user; skipping .xsession"
  fi

  enable_unit xrdp.service
  ok "xrdp will start '$session'"

  if [[ $LH_PKG == dnf ]]; then
    note 'Sound over xrdp needs pulseaudio-module-xrdp, which Fedora does not'
    note 'package; on Fedora this backend is silent. Debian/Ubuntu have it.'
  fi
}
