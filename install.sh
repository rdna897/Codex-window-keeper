#!/usr/bin/env bash
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
root_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

install -D -m 0755 "$root_dir/bin/codex-window-keeper.sh" /usr/local/bin/codex-window-keeper.sh
install -D -m 0644 "$root_dir/systemd/codex-window-keeper.service" /etc/systemd/system/codex-window-keeper.service
install -D -m 0644 "$root_dir/systemd/codex-window-keeper.timer" /etc/systemd/system/codex-window-keeper.timer
install -D -m 0644 "$root_dir/etc/default/codex-window-keeper" /etc/default/codex-window-keeper
install -d -m 0700 /var/lib/codex-window-keeper

systemctl daemon-reload
systemctl enable --now codex-window-keeper.timer
echo 'Installed and enabled. Live triggering remains disabled until LIVE_TRIGGER_ENABLED=1 is set.'
