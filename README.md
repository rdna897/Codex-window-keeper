# Window Keeper

Window Keeper is a small systemd automation that starts a five-hour service window after the previous one has expired. It periodically checks the latest available quota information and, when a new window is due, sends one minimal ephemeral request before exiting.

The service is intended for hosts where a five-hour window should begin promptly after the previous window ends. Typical uses include keeping a scheduled work period ready for later interactive use, avoiding a long idle gap after a reset, and running the check unattended from a systemd timer.

It is designed for one-shot execution. Each timer run takes a lock, checks whether the current window is already active, and exits without sending a request when no action is needed. After a successful request, it records the trigger time so repeated timer runs cannot trigger again during the same five-hour period.

The repository is intentionally **disarmed by default**. It contains no authentication, quota cache, state, or runtime logs.

## Install

The installer expects a Linux host using systemd and must be run as root. The host must already have the command-line client installed and authenticated.

### 1. Download the release archive

On the target server, download the current `main` branch archive, extract it, and enter the extracted directory:

```sh
cd /tmp
curl -fsSL https://github.com/rdna897/Codex-window-keeper/archive/refs/heads/main.tar.gz \
  -o codex-window-keeper.tar.gz
tar -xzf codex-window-keeper.tar.gz
cd Codex-window-keeper-main
```

Review the files if desired:

```sh
ls -la
sed -n '1,220p' README.md
```

### 2. Install the service and timer

Run the installer as root:

```sh
sudo ./install.sh
```

When already logged in as root, use:

```sh
./install.sh
```

The installer copies the script to `/usr/local/bin/codex-window-keeper.sh`, installs the systemd units under `/etc/systemd/system/`, installs the defaults file at `/etc/default/codex-window-keeper`, creates `/var/lib/codex-window-keeper` with mode `0700`, reloads systemd, and enables and starts the fifteen-minute timer. It does not copy credentials, quota cache data, or runtime state from the archive.

The installed defaults keep live triggering disabled:

```text
LIVE_TRIGGER_ENABLED=0
```

### 3. Test safely

Run a dry-run before enabling live requests:

```sh
sudo /usr/local/bin/codex-window-keeper.sh --dry-run
```

This shows the quota source, timing decision, and command that would be used without sending a request or consuming usage. The service itself can also be checked without changing the configuration:

```sh
sudo systemctl start codex-window-keeper.service
sudo journalctl -u codex-window-keeper.service -n 50 --no-pager
```

### 4. Enable live triggering deliberately

After confirming the dry-run output and the client authentication, edit the installed defaults file:

```sh
sudoedit /etc/default/codex-window-keeper
```

Set:

```text
LIVE_TRIGGER_ENABLED=1
```

Then reload the timer configuration:

```sh
sudo systemctl restart codex-window-keeper.timer
```

The next eligible timer run can send one request. Do not manually start the service unless you intend to perform an eligibility check immediately. A request is sent only when the quota or fallback logic says the window is due.

### 5. Verify the installation

```sh
sudo systemctl status codex-window-keeper.timer
sudo systemctl list-timers codex-window-keeper.timer
sudo systemctl is-enabled codex-window-keeper.timer
sudo journalctl -u codex-window-keeper.service -n 100 --no-pager
```

### Updating without Git

To update an installation later, download a fresh archive and rerun the installer:

```sh
cd /tmp
curl -fsSL https://github.com/rdna897/Codex-window-keeper/archive/refs/heads/main.tar.gz \
  -o codex-window-keeper.tar.gz
tar -xzf codex-window-keeper.tar.gz
cd Codex-window-keeper-main
sudo ./install.sh
```

The installer is safe to rerun. It refreshes the script and unit files while preserving `/var/lib/codex-window-keeper` and its recorded state.

### Optional Git checkout

Git is useful when you want version tracking and simpler updates. Clone the public repository with:

```sh
cd /usr/local/src
git clone https://github.com/rdna897/Codex-window-keeper.git
cd Codex-window-keeper
sudo ./install.sh
```

Update that checkout later with:

```sh
cd /usr/local/src/Codex-window-keeper
git pull --ff-only
sudo ./install.sh
```

## Behaviour

The script uses the local quota report when available. When a nonzero five-hour usage percentage is reported, it waits for the reported reset time. When the upstream report is idle and continually moves its reset field forward, it uses the timestamp of the last successful trigger plus five hours. If no report or cache is available, it uses the same local five-hour cadence after a successful baseline trigger. A lock prevents concurrent runs, and the state file prevents duplicate triggers.

The request is non-interactive and ephemeral, runs from `/tmp`, and uses a read-only sandbox. Defaults can be changed in `/etc/default/codex-window-keeper`.

## OpenCodex integration

`ocx` is the command-line entry point for [OpenCodex](https://github.com/lidge-jun/opencodex), an independent local proxy for command-line clients. OpenCodex can sit between the client and its configured provider, route requests, and expose local management information. On the reference host it is installed from the [`@bitkyc08/opencodex`](https://www.npmjs.com/package/@bitkyc08/opencodex) package and exposed at `/usr/local/bin/ocx`.

Window Keeper does not need OpenCodex to send its one request. It uses OpenCodex because the proxy can provide a structured, machine-readable view of the current five-hour quota state. On each timer run, the script asks:

```text
ocx provider quota --json
```

It reads the reported usage percentage, reset timestamp, and report age. When that information is fresh and shows an active window, the service waits for the reported reset time instead of guessing. This is the most accurate path available to this implementation because it uses the latest quota observation and the reset time supplied by the service behind the proxy.

OpenCodex is therefore an optional quota observer in this project. The actual request still goes through the installed client at `/root/.codex/packages/standalone/current/bin/codex`, or the first `codex` executable found in `PATH`.

## Operation without OpenCodex

If `/usr/local/bin/ocx` is missing, not executable, times out, or returns unusable data, the systemd service still runs normally. The timer starts `codex-window-keeper.service`; that service runs the same Bash script as root, and the script still performs its lock, state, due-time, dry-run, and request checks. Only the source of timing information changes.

The no-proxy decision path is:

1. The script first checks `/root/.opencodex/codex-quota-cache.json`. This is a cached report written by the proxy. If it is readable, has a supported quota record, and is no older than `QUOTA_MAX_AGE_SECONDS` (six hours by default), the cached usage percentage and reset timestamp are used.
2. If there is no usable cache, the script reads `/var/lib/codex-window-keeper/last_success_epoch`. This file is written only after a request completes successfully. The fallback boundary is calculated as:

   ```text
   last_success_epoch + WINDOW_SECONDS
   = last_success_epoch + 18,000 seconds
   ```

   That is five hours after the last successful trigger. The fifteen-minute timer continues to run; checks before that boundary exit without sending anything, and the first check at or after it becomes eligible to send one request.
3. If there is no quota report, no usable cache, and no previous successful trigger, the script refuses to guess and exits successfully without sending a request.

This mode is less accurate about the real server reset time. It assumes that the last successful trigger started the relevant five-hour period and schedules the next opportunity exactly five hours later. If the server reset was delayed, the prior request did not actually start the expected window, the host was offline, or the local timer missed checks, the fallback cannot see that directly. The fifteen-minute timer limits the normal detection delay to roughly fifteen minutes, but it cannot correct a difference between the local cadence and the server’s actual reset schedule.

If the cache is present but stale, the script deliberately treats it as unavailable and uses the local timestamp fallback. This avoids making a decision from old quota data. The trigger history is stored in `/var/lib/codex-window-keeper/trigger-history.log`, and a lock file in the same directory prevents concurrent timer invocations.

## Dependencies

Required on the host:

- Linux with systemd
- Bash 4 or newer
- `systemctl`, `systemd-analyze`, `flock`, `date`, `timeout`, `mktemp`, `install`, and standard core utilities
- The command line client installed at `/root/.codex/packages/standalone/current/bin/codex` or available as `codex` in `PATH`
- Existing authentication for the command line client

Required for quota-aware operation when available:

- `jq`
- The optional `ocx` command at `/usr/local/bin/ocx`, providing `ocx provider quota --json`
- Or a readable quota cache at `/root/.opencodex/codex-quota-cache.json`

The quota command and cache are optional. Without them, the service uses its own recorded successful trigger time. The first run without either source establishes no baseline and exits safely without sending a request.

## Intended operating model

The timer runs every fifteen minutes with `Persistent=true`, so a missed check is retried after the host returns. The service is normally installed system-wide and runs as root because the default client installation, authentication, and quota cache are under `/root`.

The repository configuration is disarmed by default. Set `LIVE_TRIGGER_ENABLED=1` only after reviewing the command and confirming that the host is intended to send the request automatically. Use dry-run mode first to inspect the decision and command without consuming usage.

## Inspect

```sh
systemctl status codex-window-keeper.timer
systemctl list-timers codex-window-keeper.timer
journalctl -u codex-window-keeper.service
cat /var/lib/codex-window-keeper/last_success_epoch
```

The live host may have `LIVE_TRIGGER_ENABLED=1`; the tracked template does not.
