"""Generate docs/api/API_COVERAGE.md, a per-call table of every Moonraker API
endpoint / JSON-RPC method / notification / remote method, with phobos's
implementation status and any difference from Moonraker.

Driven by:
  * the Moonraker baseline (api/api_surface.json): the authoritative call list,
  * phobos --dump-api output: registered names,
  * the curated DELTAS below: known behavioural differences.

Regenerate with:  PYTHONPATH=tools python3 -m api_scanner table \\
                    --phobos <dump.json> > docs/api/API_COVERAGE.md
"""

from __future__ import annotations

from typing import Any, Dict, List, Set, Tuple

# Status legend.
S_FULL = "✅ Full"
S_NOOP = "🚫 No-op"
S_PARTIAL = "⚠️ Partial"
S_MISSING = "❌ Missing"

# Curated differences from Moonraker. Keyed by exact JSON-RPC method name, by
# endpoint path ("path:/..."), notification ("notify:..."), remote ("remote:..."),
# or component ("component:<name>") as a fallback for a whole component.
# Value: (status, note). Anything not listed defaults to (S_FULL, MATCHES).
MATCHES = "Matches Moonraker."

DELTAS: Dict[str, Tuple[str, str]] = {
    # --- Extensions (agents) ------------------------------------------------
    "component:extensions": (S_PARTIAL, "No agent registry: `identify` does not register agent clients, so the list is empty, requests fail with AgentNotConnected, and remote methods and events go nowhere (TODO.md)."),
    "notify:notify_agent_event": (S_MISSING, "Never emitted: no agent clients are registered (TODO.md)."),
    # --- Thumbnails ---------------------------------------------------------
    "server.files.thumbnails": (S_PARTIAL, "Returns base64 `data` from the gcode header; no `.thumbs/*.png` files, so `relative_path`/`thumbnail_path` are missing (TODO.md)."),
    "path:/server/files/thumbnails": (S_PARTIAL, "See server.files.thumbnails."),
    "server.files.zip": (S_PARTIAL, "Validates the destination and returns the response fields, but creates no archive (TODO.md)."),
    # --- Announcement refresh and notification timing ----------------------
    "server.announcements.update": (S_PARTIAL, "Fetches RSS with conditional requests. Development mode skips fetching instead of reading local development feed files (TODO.md)."),
    "notify:notify_announcement_update": (S_PARTIAL, "Emitted during the handler, before the response; Moonraker schedules it after a short delay (TODO.md)."),
    "notify:notify_announcement_dismissed": (S_PARTIAL, "Emitted during the handler, before the response; Moonraker schedules it after a short delay (TODO.md)."),
    # --- PanelDue -----------------------------------------------------------
    "component:paneldue": (S_PARTIAL, "No serial device or panel responses; only the line parser and its checksum exist (TODO.md)."),
    "remote:paneldue_beep": (S_MISSING, "No PanelDue serial device, so the beep is never sent (TODO.md)."),
    # --- Deliberate host-safety no-ops -------------------------------------
    "machine.reboot": (S_NOOP, "Deliberate no-op: returns Moonraker's ok shape but never reboots the host (printer boards lack systemd; a stray call must not power-cycle the box)."),
    "machine.shutdown": (S_NOOP, "Deliberate no-op: returns ok but never shuts the host down."),
    "machine.update.system": (S_PARTIAL, "Builds apt-get commands for an injected shell. The daemon installs none, so the update is refused with NoPackageProvider before it starts."),
    "machine.update.full": (S_PARTIAL, "Runs the same Git and package steps as single-source updates. Package commands require an injected shell; the daemon installs none and refuses configured package steps before starting. Web/zip installation and service restarts are unimplemented."),
    # --- External-tool integrations (stubbed; no binary/service in-tree) ----
    "component:analysis": (S_PARTIAL, "Estimator execution is unavailable. Status reports configured paths and config-file presence with estimator_ready false; no download or runner is provided."),
    "component:notifier": (S_PARTIAL, "List records come from `[notifier <name>]`. Sending is `AppriseNotAvailable` because apprise is not linked."),
    # --- Auth ---------------------------------------------------------------
    "component:authorization": (S_FULL, "JWT + oneshot + API-key + trusted-client all enforced. The `ldap` auth source is unsupported (moonraker source only); the user `source` field is kept for shape parity."),
    "access.post_user": (S_PARTIAL, "Creates users with non-empty, dot-free names. Dotted usernames return 400 because dots denote nested DataStore keys; Moonraker can store those names. Names are not rewritten."),
    # --- Spoolman -----------------------------------------------------------
    "server.spoolman.proxy": (S_FULL, "Per-request HTTP forwarder with a ten-second deadline. V1 preserves upstream status and reason text; v2 uses the JSON message field. External text and JSON depth are validated. A live WebSocket tracks connection state and spool deletion."),
    "server.spoolman.status": (S_PARTIAL, "Reports connection state and active spool, but pending_reports stays empty because filament-use reporting is not implemented (TODO.md)."),
    # --- Machine services / init providers ---------------------------------
    "machine.services.start": (S_PARTIAL, "Dispatches to systemctl, supervisorctl, `<script_path>/<service>` or in-memory state by provider. Systemd/supervisord require discovered allowed units; simple/none accept fixed names. Provider state mapping and periodic service polling still differ (TODO.md)."),
    "machine.services.stop": (S_PARTIAL, "See machine.services.start."),
    "machine.services.restart": (S_PARTIAL, "See machine.services.start."),
    "machine.peripherals.usb": (S_PARTIAL, "No usb.ids database: class, subclass and protocol are null, and names come only from Moonraker's built-in 1d50 (Klipper, Katapult) entries."),
    "machine.peripherals.video": (S_PARTIAL, "`modes` is always [] (no format enumeration) and `libcamera_devices` is always []."),
    "machine.peripherals.canbus": (S_PARTIAL, "Returns an empty `can_uuids` list; no SocketCAN query."),
    "notify:notify_service_state_changed": (S_PARTIAL, "Sent after API service actions only; Moonraker also sends it from its periodic service-state poll."),
    # --- Power --------------------------------------------------------------
    "component:power": (S_PARTIAL, "http / gpio (sysfs `pin`) / tasmota / shelly devices do real I/O with Core released. tplink_smartplug and homeseer track state in-memory only. Shutdown/queue hooks, bound services, timers and http templates are not implemented (TODO.md)."),
    "remote:set_device_power": (S_PARTIAL, "Registered with Klippy and run off the Klippy reader; `force` is ignored, so `locked_while_printing` still applies (TODO.md)."),
    # --- Button -------------------------------------------------------------
    "notify:notify_button_event": (S_MISSING, "Never emitted: `[button]` sections and templates are not implemented (TODO.md)."),
    # --- TD-1 ---------------------------------------------------------------
    "component:td1": (S_PARTIAL, "Discovery and CSV readings work; the errors.txt and reboot handshakes are not sent, so `error` is null and reboot only forgets the device (TODO.md)."),
    # --- Sensors ------------------------------------------------------------
    "component:sensor": (S_PARTIAL, "MQTT measurements use a bounded Jinja subset. Parameter/history-field configuration is not loaded; history and notifications follow messages rather than Moonraker's sampling timer (TODO.md)."),
    "component:mqtt": (S_PARTIAL, "MQTT 3.1.1 with TLS, reconnect and API-topic dispatch. Publish replies after the write rather than PUBACK/PUBCOMP; subscribe retains its broker subscription. Klippy status publishing is not implemented (TODO.md)."),
    "server.webcams.test": (S_PARTIAL, "Probes stream/snapshot URLs with bounded HTTP requests. Relative URLs resolve against loopback; Moonraker uses the public machine address and convert_local rewriting (TODO.md)."),
    # --- Klippy-proxied printer.* ------------------------------------------
    "component:printer": (S_FULL, "Proxied to Klippy when connected (is_remote endpoints); returns the Klippy-disconnected error shape otherwise."),
}


def classify_extra(name: str, remote_names: Set[str]) -> str:
    """Classify a phobos JSON-RPC method that isn't in the static baseline list."""
    last = name.rsplit(".", 1)[-1]
    if name in remote_names or last in remote_names:
        return "Klipper remote method (also exposed as JSON-RPC)"
    if name.startswith("printer."):
        return "Klipper-proxied (is_remote) endpoint"
    return "phobos-internal shim"


def _status_for(keys: List[str], implemented: bool) -> Tuple[str, str]:
    if not implemented:
        return (S_MISSING, "Not yet implemented in phobos.")
    for k in keys:
        if k in DELTAS:
            return DELTAS[k]
    return (S_FULL, MATCHES)


def _md_escape(s: str) -> str:
    return s.replace("|", "\\|")


def _table(headers: List[str], rows: List[List[str]]) -> str:
    out = ["| " + " | ".join(headers) + " |",
           "|" + "|".join("---" for _ in headers) + "|"]
    for r in rows:
        out.append("| " + " | ".join(_md_escape(c) for c in r) + " |")
    return "\n".join(out)


def generate(baseline: Dict[str, Any], phobos: Dict[str, Any]) -> str:
    # phobos-implemented sets
    ph_paths: Set[str] = {e["path"].rstrip("/") or "/" for e in phobos.get("endpoints", [])}
    ph_methods: Set[str] = set()
    for m in phobos.get("jsonrpc_methods", []):
        ph_methods.add(m if isinstance(m, str) else m.get("method", ""))
    ph_notifs: Set[str] = set()
    for n in phobos.get("notifications", []):
        ph_notifs.add(n if isinstance(n, str) else n.get("name", ""))

    s = baseline.get("summary", {})
    lines: List[str] = []
    lines.append("# phobos API Coverage")
    lines.append("")
    lines.append("Per-call implementation status of every Moonraker API surface element, "
                 "with any behavioural difference. **Auto-generated** "
                 "(`python3 -m api_scanner table`) from the Moonraker baseline "
                 "(`api/api_surface.json`) × phobos `--dump-api` × curated deltas. "
                 "do not hand-edit; update the deltas in `tools/api_scanner/table.py`.")
    lines.append("")
    lines.append(f"- Moonraker baseline: `{s.get('moonraker_version','?')}` "
                 f"(commit `{str(s.get('moonraker_commit',''))[:12]}`).")
    lines.append(f"- Endpoints: {s.get('endpoint_count','?')} · "
                 f"JSON-RPC methods: {s.get('jsonrpc_method_count','?')} · "
                 f"notifications: {s.get('notification_count','?')} · "
                 f"remote methods: {s.get('remote_method_count','?')}.")
    lines.append("")
    lines.append("Status: ✅ Full (matches Moonraker) · ⚠️ Partial (shape matches; "
                 "behaviour differs/stubbed) · 🚫 No-op (deliberate, host-safety) · "
                 "❌ Missing.")
    lines.append("")

    # --- Endpoints ---------------------------------------------------------
    lines.append("## HTTP endpoints")
    lines.append("")
    rows: List[List[str]] = []
    n_full = n_partial = n_noop = n_missing = 0
    for e in sorted(baseline.get("endpoints", []), key=lambda x: x["path"]):
        path = e["path"]
        comp = e.get("component", "")
        methods = e.get("jsonrpc_methods", [])
        if path == "<dynamic>":
            # Moonraker's runtime endpoint-registration facility (Klipper-
            # registered endpoints). phobos handles these via the is_remote
            # proxy path, not as a fixed --dump-api route.
            status, note = (S_FULL, "Dynamic endpoint registration: Klipper-registered endpoints are proxied via the is_remote path, not a fixed route.")
        else:
            impl = (path.rstrip("/") or "/") in ph_paths
            keys = [path] + list(methods) + [f"path:{path}", f"component:{comp}"]
            status, note = _status_for(keys, impl)
        if status == S_FULL: n_full += 1
        elif status == S_PARTIAL: n_partial += 1
        elif status == S_NOOP: n_noop += 1
        else: n_missing += 1
        rows.append([
            f"`{path}`",
            ", ".join(e.get("request_types", [])),
            ", ".join(e.get("transports", [])),
            comp,
            status,
            note,
        ])
    lines.append(_table(["Path", "Verbs", "Transports", "Component", "Status", "Notes"], rows))
    lines.append("")
    lines.append(f"_Endpoints: {n_full} full, {n_partial} partial, {n_noop} no-op, {n_missing} missing._")
    lines.append("")

    # --- JSON-RPC methods --------------------------------------------------
    lines.append("## JSON-RPC methods")
    lines.append("")
    rows = []
    for m in sorted(baseline.get("jsonrpc_methods", []), key=lambda x: x["method"]):
        name = m["method"]
        impl = name in ph_methods
        comp = m.get("component", "")
        keys = [name, f"component:{comp}"]
        status, note = _status_for(keys, impl)
        rows.append([f"`{name}`", ", ".join(m.get("transports", [])), comp, status, note])
    lines.append(_table(["Method", "Transports", "Component", "Status", "Notes"], rows))
    lines.append("")

    # --- Notifications -----------------------------------------------------
    lines.append("## Notifications")
    lines.append("")
    rows = []
    for n in sorted(baseline.get("notifications", []), key=lambda x: x["name"]):
        name = n["name"]
        impl = name in ph_notifs
        keys = [f"notify:{name}", name]
        status, note = _status_for(keys, impl)
        rows.append([f"`{name}`", n.get("component", ""), status, note])
    lines.append(_table(["Notification", "Component", "Status", "Notes"], rows))
    lines.append("")

    # --- phobos methods beyond the static JSON-RPC baseline ----------------
    # Most are Moonraker functionality
    # registered through a different mechanism (Klipper remote methods, or the
    # dynamic is_remote printer.* endpoints), which the static jsonrpc_methods
    # list in the baseline doesn't enumerate. Classify each so the comparison is
    # honest about what is genuinely phobos-only.
    base_methods: Set[str] = {m["method"] for m in baseline.get("jsonrpc_methods", [])}
    base_notifs: Set[str] = {n["name"] for n in baseline.get("notifications", [])}
    remote_names: Set[str] = {r.get("name", "") for r in baseline.get("remote_methods", [])}

    extra_methods = sorted(m for m in ph_methods if m and m not in base_methods)
    extra_notifs = sorted(n for n in ph_notifs if n and n not in base_notifs)
    if extra_methods or extra_notifs:
        lines.append("## phobos methods/notifications beyond the static baseline")
        lines.append("")
        lines.append("Calls phobos registers that the static baseline lists don't enumerate. "
                     "Most are Moonraker functionality registered via remote methods or the "
                     "dynamic is_remote path; genuine phobos-only items are marked "
                     "\"phobos-internal shim\".")
        lines.append("")
        if extra_methods:
            lines.append(_table(["JSON-RPC method", "Classification"],
                                [[f"`{m}`", classify_extra(m, remote_names)] for m in extra_methods]))
            lines.append("")
        if extra_notifs:
            lines.append(_table(["Notification", "Classification"],
                                [[f"`{n}`", "phobos-internal"] for n in extra_notifs]))
            lines.append("")

    # --- Remote methods ----------------------------------------------------
    rems = baseline.get("remote_methods", [])
    if rems:
        lines.append("## Klipper→Moonraker remote methods")
        lines.append("")
        rows = []
        for r in sorted(rems, key=lambda x: x.get("name", "")):
            name = r.get("name", "")
            keys = [f"remote:{name}", name]
            status, note = _status_for(keys, True)
            rows.append([f"`{name}`", r.get("component", ""), status, note])
        lines.append(_table(["Remote method", "Component", "Status", "Notes"], rows))
        lines.append("")

    return "\n".join(lines) + "\n"
