#!/bin/sh
set -eu

log() {
  printf '%s\n' "[print-init] $*"
}

start_cups() {
  mkdir -p /run/cups/certs /var/spool/cups/tmp /var/cache/cups
  pkill cupsd >/dev/null 2>&1 || true
  /usr/sbin/cupsd -f >/tmp/cupsd.out 2>/tmp/cupsd.err &
  i=0
  while [ "$i" -lt 10 ]; do
    if lpstat -r >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    i=$((i+1))
  done
  log "cups scheduler unavailable after startup"
  cat /tmp/cupsd.err 2>/dev/null | while IFS= read -r line; do log "$line"; done || true
  return 0
}

configure_printer() {
  PRINTER_NAME="${PRINTER_NAME:-}"
  PRINTER_URI="${PRINTER_URI:-}"
  PRINTER_PPD="${PRINTER_PPD:-}"

  if [ -z "$PRINTER_NAME" ] || [ -z "$PRINTER_URI" ]; then
    log "PRINTER_NAME or PRINTER_URI not set; skipping printer setup"
    return 0
  fi

  if ! lpstat -r >/dev/null 2>&1; then
    log "cups scheduler unavailable; skipping printer setup"
    return 0
  fi

  if ! lpstat -p "$PRINTER_NAME" >/dev/null 2>&1; then
    log "creating printer queue $PRINTER_NAME -> $PRINTER_URI"
    if [ -n "$PRINTER_PPD" ] && [ -f "$PRINTER_PPD" ]; then
      lpadmin -p "$PRINTER_NAME" -E -v "$PRINTER_URI" -P "$PRINTER_PPD" >/dev/null 2>&1 || log "ESC/P-R queue setup failed"
    else
      if ! lpadmin -p "$PRINTER_NAME" -E -v "$PRINTER_URI" -m everywhere >/dev/null 2>&1; then
        log "driverless setup failed; retrying raw queue"
        lpadmin -p "$PRINTER_NAME" -E -v "$PRINTER_URI" -m raw >/dev/null 2>&1 || log "raw queue setup failed"
      fi
    fi
  fi

  lpadmin -p "$PRINTER_NAME" -o PageSize=A4 -o MediaType=PLAIN_HIGH >/dev/null 2>&1 || true
  lpadmin -d "$PRINTER_NAME" >/dev/null 2>&1 || true
  lpstat -d 2>/dev/null | while IFS= read -r line; do log "$line"; done || true
}

ensure_qqbot_plugin() {
  if openclaw plugins list 2>/tmp/qqbot-plugin-list.err | grep -qi 'stock:qqbot/index.js\|qqbot.*enabled'; then
    return 0
  fi

  version="$(node -p 'require("/app/package.json").version' 2>/dev/null || true)"
  if [ -z "$version" ]; then
    log "qqbot plugin install skipped: unable to resolve OpenClaw version"
    cat /tmp/qqbot-plugin-list.err 2>/dev/null | while IFS= read -r line; do log "$line"; done || true
    return 0
  fi

  spec="@openclaw/qqbot@$version"
  log "qqbot plugin unavailable; installing $spec"
  if openclaw plugins install "$spec" --force >/tmp/qqbot-plugin-install.out 2>/tmp/qqbot-plugin-install.err; then
    cat /tmp/qqbot-plugin-install.out 2>/dev/null | while IFS= read -r line; do log "$line"; done || true
  else
    log "qqbot plugin install failed"
    cat /tmp/qqbot-plugin-install.err 2>/dev/null | while IFS= read -r line; do log "$line"; done || true
  fi
}

patch_qqbot_reply_prefix() {
  target="/app/extensions/qqbot/src/engine/gateway/outbound-dispatch.ts"
  marker="OPENCLAW_QQBOT_REPLY_PREFIX_CONTEXT_PATCH"

  if [ ! -f "$target" ]; then
    log "qqbot reply prefix patch skipped: $target not found"
    return 0
  fi

  python3 - "$target" "$marker" <<'PY'
import sys
from pathlib import Path

target = Path(sys.argv[1])
marker = sys.argv[2]
text = target.read_text(encoding="utf-8")

if marker in text:
    raise SystemExit(0)

original = text
import_line = 'import type { FinalizedMsgContext } from "openclaw/plugin-sdk/reply-runtime";\n'
replacement_import = (
    'import { createReplyPrefixContext } from "openclaw/plugin-sdk/channel-reply-pipeline";\n'
    + import_line
)
if import_line not in text:
    raise SystemExit("qqbot reply prefix patch failed: reply-runtime import not found")
text = text.replace(import_line, replacement_import, 1)

dispatch_block = """  // ---- Dispatch ----
  const messagesConfig = runtime.channel.reply.resolveEffectiveMessagesConfig(
    cfg,
    inbound.route.agentId,
  );
"""
replacement_dispatch_block = f"""  // ---- Dispatch ----
  const replyPrefixContext = createReplyPrefixContext({{
    cfg,
    channel: "qqbot",
    accountId: inbound.route.accountId,
    agentId: inbound.route.agentId,
  }});
  const messagesConfig = {{ responsePrefix: replyPrefixContext.responsePrefix }};
  const {marker} = "2026-05-05.1";
  void {marker};
"""
if dispatch_block not in text:
    raise SystemExit("qqbot reply prefix patch failed: dispatch config block not found")
text = text.replace(dispatch_block, replacement_dispatch_block, 1)

dispatcher_prefix = """              responsePrefix: messagesConfig.responsePrefix,
              deliver: async (payload: ReplyDeliverPayload, info: { kind: string }) => {
"""
replacement_dispatcher_prefix = """              responsePrefix: messagesConfig.responsePrefix,
              responsePrefixContextProvider: replyPrefixContext.responsePrefixContextProvider,
              deliver: async (payload: ReplyDeliverPayload, info: { kind: string }) => {
"""
if dispatcher_prefix not in text:
    raise SystemExit("qqbot reply prefix patch failed: dispatcher prefix block not found")
text = text.replace(dispatcher_prefix, replacement_dispatcher_prefix, 1)

reply_options = "            replyOptions: {\n"
if reply_options not in text:
    raise SystemExit("qqbot reply prefix patch failed: replyOptions block not found")
text = text.replace(
    reply_options,
    reply_options + "              onModelSelected: replyPrefixContext.onModelSelected,\n",
    1,
)

backup = target.with_suffix(target.suffix + ".bak-openclaw-prefix")
if not backup.exists():
    backup.write_text(original, encoding="utf-8")
target.write_text(text, encoding="utf-8")
print(f"patched {target}")
PY
  status=$?
  if [ "$status" -eq 0 ]; then
    log "qqbot reply prefix patch ensured"
  else
    log "qqbot reply prefix patch failed"
    return "$status"
  fi
}

ensure_browser_config() {
  config_path="/home/node/.openclaw/openclaw.json"

  mkdir -p /home/node/.openclaw

  python3 - "$config_path" <<'PY'
import json
import os
import sys
from pathlib import Path

config_path = Path(sys.argv[1])

if config_path.exists():
    try:
        config = json.loads(config_path.read_text(encoding="utf-8"))
    except Exception:
        raise SystemExit("invalid openclaw.json; refusing to rewrite browser config")
else:
    config = {}

browser = config.setdefault("browser", {})
browser.setdefault("enabled", True)
browser.setdefault("defaultProfile", "openclaw")
browser.setdefault("headless", True)
browser.setdefault("noSandbox", True)

if os.path.exists("/usr/bin/chromium"):
    browser.setdefault("executablePath", "/usr/bin/chromium")

config_path.write_text(
    json.dumps(config, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)
PY

  log "browser defaults ensured for headless Chromium"
}

start_cups
configure_printer
ensure_qqbot_plugin
patch_qqbot_reply_prefix
ensure_browser_config

if [ "$#" -eq 0 ]; then
  set -- node openclaw.mjs gateway --allow-unconfigured
fi

exec docker-entrypoint.sh "$@"
