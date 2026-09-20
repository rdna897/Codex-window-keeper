#!/usr/bin/env bash
#
# codex-window-keeper.sh - start a Codex five-hour window after it expires.
#
# A Codex five-hour window only starts counting when a request is made.  This
# script sends one very cheap ephemeral request at the reset boundary so the
# window does not sit idle, then exits.  It sends at most one request per
# five-hour window.
#
# Timing sources, in order of preference:
#   1. live report   ocx provider quota --json
#   2. cached report /root/.opencodex/codex-quota-cache.json     (written by the proxy)
#   3. own state     /var/lib/codex-window-keeper/last_success_epoch + 5 hours
#
# Two decision modes are supported because the quota report has two shapes:
#   * window in use (fiveHourPercent > 0): the report carries a real upstream
#     reset timestamp.  Wait for it, then send exactly one request.
#   * window idle (fiveHourPercent == 0): the upstream has fully recovered the
#     budget and the proxy recomputes fiveHourResetAt as "now + 5h" on every
#     refresh, so that timestamp never arrives.  In this state we keep our own
#     five-hour cadence from the last successful trigger.
#
# A live request is sent only when the trigger is due AND LIVE_TRIGGER_ENABLED=1
# in /etc/default/codex-window-keeper.  Use --dry-run to see the decision and
# the exact command without contacting Codex at all.
#
# Verified against the installed CLI: exec --ephemeral --json --model --config
# --sandbox --cd --skip-git-repo-check.
#
set -Eeuo pipefail
umask 077

DEFAULTS_FILE="/etc/default/codex-window-keeper"
if [[ -r "$DEFAULTS_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$DEFAULTS_FILE"
fi

STATE_DIR="${STATE_DIR:-/var/lib/codex-window-keeper}"
LOCK_FILE="$STATE_DIR/keeper.lock"
LAST_SUCCESS_FILE="$STATE_DIR/last_success_epoch"
HISTORY_FILE="$STATE_DIR/trigger-history.log"
QUOTA_CACHE_FILE="${QUOTA_CACHE_FILE:-/root/.opencodex/codex-quota-cache.json}"

WINDOW_SECONDS="${WINDOW_SECONDS:-18000}"
QUOTA_MAX_AGE_SECONDS="${QUOTA_MAX_AGE_SECONDS:-21600}"
LIVE_TRIGGER_ENABLED="${LIVE_TRIGGER_ENABLED:-0}"
KEEPER_MODEL="${KEEPER_MODEL:-gpt-5.6-luna}"
KEEPER_REASONING_EFFORT="${KEEPER_REASONING_EFFORT:-low}"
KEEPER_PROMPT="${KEEPER_PROMPT:-Reply with exactly: Hi}"
KEEPER_WORKDIR="${KEEPER_WORKDIR:-/tmp}"
EXEC_TIMEOUT_SECONDS="${EXEC_TIMEOUT_SECONDS:-180}"
OCX_BIN="${OCX_BIN:-/usr/local/bin/ocx}"
CODEX_BIN="${CODEX_BIN:-}"

DRY_RUN=0
case "${1:-}" in
  "") ;;
  --dry-run) DRY_RUN=1 ;;
  --help|-h)
    cat <<'EOF'
Usage: codex-window-keeper.sh [--dry-run]

Starts a Codex five-hour window once it has expired.  Live requests require
LIVE_TRIGGER_ENABLED=1 in /etc/default/codex-window-keeper.  --dry-run never
invokes Codex and never consumes usage.
EOF
    exit 0
    ;;
  *)
    echo "usage: $0 [--dry-run]" >&2
    exit 2
    ;;
esac

log() {
  printf '[codex-window-keeper] %s %s\n' "$(date --iso-8601=seconds)" "$*"
}

is_uint() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

format_epoch() {
  if is_uint "${1:-}" && (( $1 > 0 )); then
    date --date="@$1" '+%Y-%m-%d %H:%M:%S %Z'
  else
    printf 'unknown'
  fi
}

if ! is_uint "$WINDOW_SECONDS" || (( WINDOW_SECONDS <= 0 )); then
  log "ERROR: WINDOW_SECONDS must be a positive integer"
  exit 1
fi
if ! is_uint "$QUOTA_MAX_AGE_SECONDS" || (( QUOTA_MAX_AGE_SECONDS <= 0 )); then
  log "ERROR: QUOTA_MAX_AGE_SECONDS must be a positive integer"
  exit 1
fi
if [[ "$LIVE_TRIGGER_ENABLED" != 0 && "$LIVE_TRIGGER_ENABLED" != 1 ]]; then
  log "ERROR: LIVE_TRIGGER_ENABLED must be 0 or 1"
  exit 1
fi

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

# The lock keeps a manual run and a timer run from sending two requests at once.
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "another run is already holding the lock; nothing to do"
  exit 0
fi

last_success_epoch=0
if [[ -r "$LAST_SUCCESS_FILE" ]]; then
  read -r candidate_last_success < "$LAST_SUCCESS_FILE" || true
  if is_uint "${candidate_last_success:-}"; then
    last_success_epoch="$candidate_last_success"
  fi
fi

now_epoch="$(date +%s)"
now_ms="$((now_epoch * 1000))"

# Resolve the installed CLI up front so --dry-run can print the exact command.
if [[ -z "$CODEX_BIN" ]]; then
  if [[ -x /root/.codex/packages/standalone/current/bin/codex ]]; then
    CODEX_BIN="/root/.codex/packages/standalone/current/bin/codex"
  else
    CODEX_BIN="$(command -v codex || true)"
  fi
fi

# Extract "updatedMillis<TAB>resetEpoch<TAB>usedPercent" from a quota document.
# Deliberately tolerant: a missing updatedAt is treated as unknown rather than
# as a reason to discard the document, and a missing percentage becomes -1.
extract_openai_quota() {
  jq -er '
    [
      .reports[]
      | select(.provider == "openai")
      | ((.aggregation.currentAccount.quota // {}) + (.quota // {})) as $q
      | select(($q.fiveHourResetAt // $q.shortResetAt) != null)
      | [
          (($q.updatedAt // .updatedAt // 0) | tonumber),
          (($q.fiveHourResetAt // $q.shortResetAt) | tonumber),
          (($q.fiveHourPercent // $q.shortPercent // -1) | tonumber)
        ]
    ]
    | first // empty
    | @tsv
  ' 2>/dev/null
}

# Extract the same three fields from the proxy cache, which has its own shape.
extract_cached_quota() {
  jq -er '
    (.mainPolicyQuota.quota // .quotas.__main__ // {}) as $q
    | select(($q.shortResetAt // $q.fiveHourResetAt) != null)
    | [
        (($q.updatedAt // 0) | tonumber),
        (($q.shortResetAt // $q.fiveHourResetAt) | tonumber),
        (($q.shortPercent // $q.fiveHourPercent // -1) | tonumber)
      ]
    | @tsv
  ' 2>/dev/null
}

# Store a candidate reading.  Returns 0 when it is usable, 1 when unusable or
# too stale to trust.
accept_reading() {
  local updated_ms="$1" reset_epoch="$2" used_percent="$3" source_name="$4"
  is_uint "$updated_ms" || return 1
  is_uint "$reset_epoch" || return 1
  (( reset_epoch > 0 )) || return 1
  is_uint "$used_percent" || return 1
  (( used_percent <= 100 )) || return 1
  if (( updated_ms > 0 )) && (( now_ms - updated_ms > QUOTA_MAX_AGE_SECONDS * 1000 )); then
    return 1
  fi
  quota_source="$source_name"
  quota_updated_ms="$updated_ms"
  quota_reset_epoch="$reset_epoch"
  quota_used_percent="$used_percent"
  return 0
}

quota_source="none"
quota_updated_ms=0
quota_reset_epoch=0
quota_used_percent=-1

# Source 1: live report from the OpenCodex proxy.
if [[ -x "$OCX_BIN" ]] && command -v jq >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
  if quota_json="$(timeout 30 "$OCX_BIN" provider quota --json 2>/dev/null)" && [[ -n "$quota_json" ]]; then
    if quota_tsv="$(extract_openai_quota <<<"$quota_json")" && [[ -n "$quota_tsv" ]]; then
      IFS=$'\t' read -r reading_updated_ms reading_reset_epoch reading_used_percent <<< "$quota_tsv"
      if ! accept_reading "$reading_updated_ms" "$reading_reset_epoch" "$reading_used_percent" "ocx-live-report"; then
        log "live quota report unusable (updated=$reading_updated_ms reset=$reading_reset_epoch percent=$reading_used_percent); trying the proxy cache"
      fi
    else
      log "live quota report has no five-hour reset field; trying the proxy cache"
    fi
  else
    log "live quota report unavailable; trying the proxy cache"
  fi
fi

# Source 2: the cache the proxy writes on every observation.
if [[ "$quota_source" == "none" && -r "$QUOTA_CACHE_FILE" ]] && command -v jq >/dev/null 2>&1; then
  if cache_tsv="$(extract_cached_quota < "$QUOTA_CACHE_FILE")" && [[ -n "$cache_tsv" ]]; then
    IFS=$'\t' read -r reading_updated_ms reading_reset_epoch reading_used_percent <<< "$cache_tsv"
    if ! accept_reading "$reading_updated_ms" "$reading_reset_epoch" "$reading_used_percent" "ocx-quota-cache"; then
      log "proxy cache is stale or unusable (updated=$reading_updated_ms reset=$reading_reset_epoch percent=$reading_used_percent)"
    fi
  else
    log "proxy cache has no usable five-hour reset field"
  fi
fi

due=0
due_reason=""

if [[ "$quota_source" != "none" ]]; then
  quota_updated_text="$(format_epoch "$((quota_updated_ms / 1000))")"
  quota_reset_text="$(format_epoch "$quota_reset_epoch")"

  if (( quota_used_percent == 0 )); then
    # Fully recovered: no upstream reset to wait for, so keep our own cadence.
    if (( last_success_epoch == 0 )); then
      due=1
      due_reason="five-hour budget is fully recovered and no keeper trigger has ever been recorded"
    elif (( now_epoch - last_success_epoch >= WINDOW_SECONDS )); then
      due=1
      due_reason="five-hour budget is fully recovered and $(format_epoch "$last_success_epoch") is more than $WINDOW_SECONDS seconds ago"
    else
      next_self_epoch="$((last_success_epoch + WINDOW_SECONDS))"
      log "window idle (${quota_used_percent}% used, source=$quota_source); self-cadence trigger not due until $(format_epoch "$next_self_epoch")"
      exit 0
    fi
  elif (( now_epoch < quota_reset_epoch )); then
    log "window active: ${quota_used_percent}% used; next reset $quota_reset_text (source=$quota_source, observed $quota_updated_text)"
    exit 0
  elif (( last_success_epoch >= quota_reset_epoch )); then
    log "reset at $quota_reset_text already has a successful keeper trigger at $(format_epoch "$last_success_epoch"); nothing to do"
    exit 0
  else
    due=1
    due_reason="reset at $quota_reset_text has passed with no keeper trigger for it"
  fi
else
  # No trustworthy reading at all: only our own state file is available.
  if (( last_success_epoch == 0 )); then
    log "no quota reading and no keeper baseline; refusing to guess when the window expired"
    exit 0
  fi
  fallback_reset_epoch="$((last_success_epoch + WINDOW_SECONDS))"
  if (( now_epoch < fallback_reset_epoch )); then
    log "no quota reading; fallback window active until $(format_epoch "$fallback_reset_epoch")"
    exit 0
  fi
  due=1
  due_reason="no quota reading and the fallback five-hour window from $(format_epoch "$last_success_epoch") has expired"
fi

if (( due == 1 )); then
  log "trigger due: $due_reason"
fi

if [[ "$DRY_RUN" == 1 || "$LIVE_TRIGGER_ENABLED" == 0 ]]; then
  if [[ "$DRY_RUN" == 1 ]]; then
    log "dry-run: no Codex request will be sent"
  else
    log "live trigger is disarmed by $DEFAULTS_FILE; no Codex request will be sent"
  fi
  log "would run: $CODEX_BIN exec --ephemeral --json --model $KEEPER_MODEL --config 'model_reasoning_effort=\"$KEEPER_REASONING_EFFORT\"' --sandbox read-only --cd $KEEPER_WORKDIR --skip-git-repo-check \"$KEEPER_PROMPT\""
  exit 0
fi

if [[ -z "$CODEX_BIN" || ! -x "$CODEX_BIN" ]]; then
  log "ERROR: no executable Codex CLI was found"
  exit 1
fi
if ! command -v timeout >/dev/null 2>&1; then
  log "ERROR: timeout command is required for a bounded live request"
  exit 1
fi

codex_args=(
  exec
  --ephemeral
  --json
  --model "$KEEPER_MODEL"
  --config "model_reasoning_effort=\"$KEEPER_REASONING_EFFORT\""
  --sandbox read-only
  --cd "$KEEPER_WORKDIR"
  --skip-git-repo-check
  "$KEEPER_PROMPT"
)
log "sending one live keeper request with model=$KEEPER_MODEL effort=$KEEPER_REASONING_EFFORT"
log "live command: $CODEX_BIN ${codex_args[*]}"

output_file="$(mktemp "$STATE_DIR/trigger-output.XXXXXX")"
cleanup_output() {
  rm -f -- "$output_file"
}
trap cleanup_output EXIT

if timeout "$EXEC_TIMEOUT_SECONDS" "$CODEX_BIN" "${codex_args[@]}" >"$output_file" 2>&1; then
  trigger_epoch="$(date +%s)"
  state_tmp="$(mktemp "$STATE_DIR/last_success.XXXXXX")"
  printf '%s\n' "$trigger_epoch" > "$state_tmp"
  chmod 600 "$state_tmp"
  mv -f -- "$state_tmp" "$LAST_SUCCESS_FILE"
  printf 'timestamp=%s source=%s reset=%s percent=%s model=%s effort=%s reason=%s\n' \
    "$trigger_epoch" "$quota_source" "$quota_reset_epoch" "$quota_used_percent" \
    "$KEEPER_MODEL" "$KEEPER_REASONING_EFFORT" "$due_reason" >> "$HISTORY_FILE"
  log "live keeper request succeeded at $(format_epoch "$trigger_epoch"); recorded timestamp"
  if [[ -s "$output_file" ]]; then
    log "Codex output tail:"
    tail -n 20 "$output_file"
  fi
  exit 0
else
  request_status=$?
fi

log "ERROR: live keeper request failed or timed out (exit=$request_status)"
if [[ -s "$output_file" ]]; then
  log "Codex failure output tail:"
  tail -n 40 "$output_file"
fi
exit "$request_status"
