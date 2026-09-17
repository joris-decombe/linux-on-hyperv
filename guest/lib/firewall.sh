# Firewall.
#
# Fedora runs firewalld with a default-deny inbound zone, so RDP needs an
# explicit rule.
#
# That rule is a single address: the Windows host. The desktop is served to the
# machine running the hypervisor and to nothing else, so anything wider is
# surface with no purpose. On a bridged switch the guest holds a real LAN
# address, and a subnet rule there exposes the session -- and its login screen
# -- to every device on the network, including whatever else is on the Wi-Fi.
#
# LH_RDP_ALLOW_FROM overrides the detected host address, for the case where the
# desktop really is meant to be reachable from elsewhere.

lh_firewall() {
  step 'Firewall (RDP)'

  if ! has firewall-cmd; then
    warn 'firewalld not installed; skipping. Open TCP/UDP 3389 yourself if something blocks it.'
    return 0
  fi

  if ! systemctl is-active --quiet firewalld 2>/dev/null; then
    note 'firewalld installed but not running; nothing to open.'
    return 0
  fi

  local allow
  allow=${LH_RDP_ALLOW_FROM:-$(lh_host_address)}

  if [[ -z $allow ]]; then
    # Refuse rather than fall back to something wider. An unattended run that
    # quietly opens the desktop to the whole subnet is worse than one that
    # leaves it shut and says so.
    warn 'Could not determine the host address, so RDP was NOT opened.'
    note 'Set LH_RDP_ALLOW_FROM=<address or CIDR> and re-run: sudo bash setup.sh --only firewall'
    return 0
  fi

  # Clear any earlier, wider rule this kit added, or tightening the scope on a
  # re-run would leave the old permissive rule sitting underneath the new one.
  local existing
  while read -r rule; do
    [[ $rule == *"port=\"$LH_RDP_PORT\""* ]] || continue
    run firewall-cmd --permanent --remove-rich-rule="$rule" >/dev/null 2>&1
  done < <(firewall-cmd --permanent --list-rich-rules 2>/dev/null)
  existing=$(firewall-cmd --permanent --list-services 2>/dev/null)
  [[ $existing == *rdp* ]] && run firewall-cmd --permanent --remove-service=rdp >/dev/null 2>&1

  ok "Allowing RDP from $allow only"
  run firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=\"$allow\" port port=\"$LH_RDP_PORT\" protocol=\"tcp\" accept" >/dev/null ||
    warn 'could not add the TCP rule'
  # RDP can use UDP for a lower-latency transport; mstsc falls back to TCP
  # without it, so this is an improvement rather than a requirement.
  run firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=\"$allow\" port port=\"$LH_RDP_PORT\" protocol=\"udp\" accept" >/dev/null ||
    warn 'could not add the UDP rule'

  run firewall-cmd --reload >/dev/null || warn 'firewall-cmd --reload failed'
  ok 'Rules applied'
}

# The Windows host's address on the link the guest is connected to.
#
# The default route's gateway is right for the Hyper-V Default Switch, where
# the host *is* the gateway and renumbers on every host reboot. On an external
# switch the gateway is the physical router instead, and the host is an
# ordinary peer -- so prefer the address that is already talking to us over
# SSH, which is the host whenever this is driven by the Windows module.
lh_host_address() {
  local addr
  # SSH_CONNECTION is "<client ip> <client port> <server ip> <server port>".
  addr=$(awk '{ print $1 }' <<<"${SSH_CONNECTION:-}")
  if [[ -n $addr && $addr != *:* ]]; then
    printf '%s' "$addr"
    return 0
  fi
  # Not over SSH -- the first-boot unit, or a console run. Fall back to the
  # default gateway, correct on the Default Switch and a sane guess elsewhere.
  ip -4 route show default 2>/dev/null | awk '{ print $3; exit }'
}

# Derive the subnet from the address the guest actually holds, so this works on
# the Hyper-V Default Switch (NAT, renumbered every host reboot) and on an
# external switch (a real LAN address) without being told which.
lh_guest_subnet() {
  local cidr
  cidr=$(ip -4 -o addr show scope global 2>/dev/null | awk '{ print $4 }' | head -1)
  [[ -n $cidr ]] || return 0
  python3 - "$cidr" <<'PY' 2>/dev/null
import ipaddress, sys
print(ipaddress.ip_network(sys.argv[1], strict=False))
PY
}

lh_primary_address() {
  ip -4 -o addr show scope global 2>/dev/null | awk '{ print $4 }' | cut -d/ -f1 | head -1
}
