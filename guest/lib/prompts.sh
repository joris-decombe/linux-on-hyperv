# Removing prompts that ask for a password you have already given.
#
# A first login over RDP asked for the same password three times: once at the
# RDP credential gate, once at GDM, and once at a polkit dialog for "update
# metadata" that appeared behind the welcome tour before the desktop had even
# settled. The first two are structural -- one authenticates to the daemon, the
# other authenticates the session. The third is GNOME Software refreshing
# package metadata, and on a disposable VM it is pure friction.
#
# None of this weakens the machine: refreshing a repository index is a
# read-only operation that Fedora already lets any user trigger from the
# command line without authenticating.

lh_prompts() {
  step 'Prompts and first-run noise'

  # Two different dialogs appeared on a single first login -- "update metadata"
  # (fwupd) and "update information about software" (PackageKit) -- so this
  # allows both by name rather than fixing one and waiting for the next.
  #
  # Each is a refresh of a downloaded index. Neither installs anything, and the
  # actions that do install are deliberately left alone: a blanket
  # org.freedesktop.packagekit.* rule would also cover package installation and
  # removal, which should keep asking.
  write_file /etc/polkit-1/rules.d/49-linux-on-hyperv-metadata.rules <<'RULES'
// Managed by linux-on-hyperv. Re-running setup.sh overwrites this.
//
// Refreshing metadata is read-only -- any user can already do the same thing
// with `dnf makecache` and no password -- so prompting for it buys nothing,
// and it lands on the user seconds after they have authenticated twice to get
// as far as the desktop.
polkit.addRule(function (action, subject) {
  var refresh = [
    'org.freedesktop.packagekit.system-sources-refresh',
    'org.freedesktop.packagekit.system-sources-configure',
    'org.freedesktop.fwupd.update-metadata',
    'org.freedesktop.fwupd.downgrade-hardware',
  ];
  if (refresh.indexOf(action.id) >= 0 && subject.isInGroup('wheel')) {
    return polkit.Result.YES;
  }
});
RULES

  # Better than authorising the prompts is not generating them. GNOME Software
  # polls for updates in the background, which is what raises them; on a VM
  # rebuilt from a profile in twenty minutes that is not worth a single click.
  write_file /etc/dconf/db/local.d/49-linux-on-hyperv-updates <<DCONF
$LH_STAMP
[org/gnome/software]
download-updates=false
download-updates-notify=false
DCONF

  # A Hyper-V guest has no firmware anyone can flash, so the firmware metadata
  # refresh is pure noise here.
  if systemctl list-unit-files fwupd-refresh.service >/dev/null 2>&1; then
    run systemctl disable --now fwupd-refresh.timer 2>/dev/null || true
  fi

  # The welcome tour is what the polkit dialog appeared on top of. Hidden=true
  # in /etc/xdg/autostart masks the system copy without deleting a packaged
  # file, so a dnf update does not quietly bring it back.
  if [[ -f /usr/share/applications/org.gnome.Tour.desktop ]] ||
    [[ -f /etc/xdg/autostart/org.gnome.Tour.desktop ]]; then
    write_file /etc/xdg/autostart/org.gnome.Tour.desktop <<'TOUR'
[Desktop Entry]
Type=Application
Name=GNOME Tour
Exec=/bin/true
Hidden=true
X-GNOME-Autostart-enabled=false
TOUR
  fi

  # The shell shows its own welcome dialog once per major version. gsettings
  # cannot set it from here -- there is no session bus to talk to when this
  # runs from the first-boot unit -- so write a system-wide dconf default,
  # which applies to every user and is still overridable per user.
  local version
  version=$(gnome-shell --version 2>/dev/null | grep -oE '[0-9]+' | head -1)
  if [[ -n $version ]]; then
    write_file /etc/dconf/db/local.d/50-linux-on-hyperv <<DCONF
$LH_STAMP
[org/gnome/shell]
welcome-dialog-last-shown-version='$version'
DCONF
    run dconf update || warn 'dconf update failed; the welcome dialog may still appear'
  fi

  lh_autologin
}

# Optional, and off unless asked for: it trades the console's lock screen for
# one less prompt over RDP.
lh_autologin() {
  [[ ${LH_AUTOLOGIN:-0} == 1 ]] || {
    note 'GDM will still ask for a password (pass --autologin to skip it).'
    return 0
  }

  local user
  user=$(target_user)

  # This applies to the Hyper-V console too, which is the whole cost: anyone at
  # the console gets a desktop without authenticating. Worth it only because
  # the RDP path has already authenticated at the credential gate.
  write_file /etc/gdm/custom.conf <<GDM
$LH_STAMP
[daemon]
AutomaticLoginEnable=True
AutomaticLogin=$user

[security]

[xdmcp]

[chooser]

[debug]
GDM
  warn "automatic login enabled for '$user' -- the Hyper-V console is now unlocked too"
}
