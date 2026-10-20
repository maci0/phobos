"""Generate docs/api/API_COVERAGE.md, a per-call table of every Moonraker API
endpoint / JSON-RPC method / notification / remote method, with phobos's
implementation status and any difference from Moonraker.

Driven by:
  * the Moonraker baseline (api/api_surface.json): the authoritative call list,
  * phobos --dump-api output: registered names,
  * the curated DELTAS below: known behavioural differences.

Regenerate with:  PYTHONPATH=tools uv run python -m api_scanner table \\
                    --phobos <dump.json> > docs/api/API_COVERAGE.md
"""

from __future__ import annotations

# Baselines and runtime dumps contain heterogeneous JSON records.
from typing import Any

# Status legend.
S_FULL = "✅ Full"
S_NOOP = "🚫 No-op"
S_PARTIAL = "⚠️ Partial"
S_MISSING = "❌ Missing"

# Curated differences from Moonraker. Keyed by exact JSON-RPC method name, by
# endpoint path ("path:/..."), notification ("notify:..."), remote ("remote:..."),
# or component ("component:<name>") as a fallback for a whole component.
# Value: (status, note). Anything not listed defaults to (S_FULL, MATCHES).
MATCHES = "No recorded behavior difference."

DELTAS: dict[str, tuple[str, str]] = {
    # Agent sessions and bidirectional requests.
    "component:extensions": (
        S_FULL,
        "WebSocket agent registration, bounded bidirectional RPC, owned Klippy methods and agent events are implemented. Disconnect removes registrations and wakes pending callers.",
    ),
    "notify:notify_agent_event": (
        S_FULL,
        "Agent connection, disconnection and custom events are emitted to other connections.",
    ),
    # Files use checked roots and publish completed replacements atomically.
    "server.files.thumbnails": (
        S_FULL,
        "Extracts embedded PNGs to .thumbs files; metadata and thumbnail_path name downloadable files under the gcodes root.",
    ),
    "path:/server/files/thumbnails": (S_FULL, "See server.files.thumbnails."),
    "server.files.zip": (
        S_PARTIAL,
        "Writes atomic ZIP32 archives with DEFLATE or stored entries. ZIP64 is rejected; source lists are bounded to 4096 files, 1 MiB of retained paths and 65536 examined directory entries. See docs/FILE_MANAGEMENT.md.",
    ),
    "server.announcements.update": (
        S_FULL,
        "Refreshes RSS with conditional requests. Development mode reads <data_path>/development/announcements/<feed>.xml.",
    ),
    "notify:notify_announcement_update": (
        S_FULL,
        "Handler updates schedule an owned notification after 50 ms.",
    ),
    "notify:notify_announcement_dismissed": (
        S_FULL,
        "Dismissal schedules an owned notification after 50 ms.",
    ),
    "component:paneldue": (
        S_FULL,
        "Configured serial I/O, bounded command queues, Klippy state and panel responses are implemented; protocol tests use pseudo-terminals.",
    ),
    "remote:paneldue_beep": (
        S_FULL,
        "Forwards the beep to the configured PanelDue serial worker.",
    ),
    # Deliberate host-safety and optional-runner behavior.
    "machine.reboot": (
        S_NOOP,
        "Deliberate no-op: returns ok without rebooting the host.",
    ),
    "machine.shutdown": (
        S_NOOP,
        "Deliberate no-op: returns ok without shutting down the host.",
    ),
    "remote:reboot_machine": (
        S_NOOP,
        "Host reboot is deliberately disabled; the remote call executes no host action.",
    ),
    "remote:shutdown_machine": (
        S_NOOP,
        "Host shutdown is deliberately disabled; the remote call executes no host action.",
    ),
    "machine.update.system": (
        S_PARTIAL,
        "Package commands require an injected runner. The daemon installs none and refuses them with NoPackageProvider before execution.",
    ),
    "machine.update.full": (
        S_PARTIAL,
        "Runs configured Git and Web/ZIP updates, including managed-service restarts. Package steps require an injected runner and are refused before starting when it is absent. See docs/UPDATES.md.",
    ),
    "machine.update.status": (
        S_PARTIAL,
        "Reads Git and release caches and installed state. github_rate_limit, github_requests_remaining and github_limit_reset_time remain null because release requests do not retain those headers.",
    ),
    "component:analysis": (
        S_PARTIAL,
        "Estimator execution requires an injected runner; the daemon provides no runner or download. See docs/ANALYSIS.md for execution, file-safety and lifecycle limits.",
    ),
    "component:notifier": (
        S_PARTIAL,
        "Lists configured notifier records. Sending fails with AppriseNotAvailable; Apprise and full Jinja2 are outside scope.",
    ),
    "remote:notify": (
        S_PARTIAL,
        "Resolves configured notifier names, then returns AppriseNotAvailable. Apprise delivery is outside scope.",
    ),
    # Authentication and implementation identity.
    "component:authorization": (
        S_PARTIAL,
        "JWT, oneshot tokens, API keys and trusted IP/CIDR clients are enforced. LDAP and reverse-DNS trusted_domains are not implemented.",
    ),
    "access.post_user": (
        S_PARTIAL,
        "Creates users with non-empty, dot-free names. Dotted usernames return 400 because dots denote nested DataStore keys; Moonraker can store those names. Names are not rewritten.",
    ),
    "server.info": (
        S_FULL,
        "Reports compatibility API 1.5.0 and phobos software identity by default. These are implementation identity fields, rather than Forge-X's older API/version values.",
    ),
    "machine.system_info": (
        S_PARTIAL,
        "Collects native host information. Python version fields remain a stub; phobos does not claim to run CPython.",
    ),
    "server.spoolman.proxy": (
        S_FULL,
        "HTTP forwarding has a ten-second deadline. V1 preserves upstream status and reason text; v2 uses the JSON message field. Text and depth are validated. WebSocket state tracks connectivity and spool deletion.",
    ),
    "server.spoolman.status": (
        S_FULL,
        "Reports connection state, active spool and pending filament use. Extrusion accounting retains failed reports and retries at sync_rate; the active spool is checked on reconnect.",
    ),
    # Machine providers and peripherals.
    "machine.services.start": (
        S_FULL,
        "Dispatches through the configured provider and allowed-service validation. Systemd/supervisord polling refreshes state; simple/none preserve their fixed-name behavior. See docs/MACHINE.md.",
    ),
    "machine.services.stop": (S_FULL, "See machine.services.start."),
    "machine.services.restart": (S_FULL, "See machine.services.start."),
    "machine.peripherals.usb": (
        S_FULL,
        "Streams vendor, product and class names from the owned usb.ids cache, with built-in OpenMoko/Klipper fallback entries. The daemon starts a bounded, atomic cache download.",
    ),
    "machine.peripherals.video": (
        S_PARTIAL,
        "Enumerates V4L2 formats and discrete resolutions. libcamera_devices remains empty.",
    ),
    "machine.peripherals.canbus": (
        S_PARTIAL,
        "Queries unassigned Klipper/Katapult CAN nodes with a two-second deadline. Unavailable interfaces deliberately return an empty list instead of a missing-device 500.",
    ),
    "notify:notify_service_state_changed": (
        S_FULL,
        "Emitted for successful API actions and changes found by periodic provider polling.",
    ),
    # Native device backends and the bounded template subset.
    "component:power": (
        S_PARTIAL,
        "HTTP, GPIO, Tasmota and Shelly perform device I/O with shutdown/queue hooks, service bindings, timers and HTTP templates. Other backends, including tplink_smartplug and homeseer, keep state in memory unless explicit HTTP URLs are configured. Templates use a bounded subset; see docs/POWER_BUTTONS.md.",
    ),
    "remote:set_device_power": (
        S_FULL,
        "The internal-only remote method accepts force. Public endpoints cannot bypass the printing lock; failed calls name the resolved state.",
    ),
    "notify:notify_button_event": (
        S_FULL,
        "GPIO button templates emit the configured button name, event fields and auxiliary value, at most once per rendered template.",
    ),
    "component:td1": (
        S_FULL,
        "Owned persistent readers retrieve errors.txt, expose nullable initial readings and UTC scan times, and perform the device settings/reboot handshake. Physical device timing remains unverified.",
    ),
    "component:sensor": (
        S_PARTIAL,
        "Loads parameter/history metadata, replaces readings per message, samples and notifies every second, and records MQTT disconnect errors. Templates implement a bounded subset rather than full Jinja2.",
    ),
    "component:mqtt": (
        S_PARTIAL,
        "Supports MQTT 3.1/3.1.1/5, TLS, reconnect, QoS acknowledgements, temporary subscription cleanup and Klippy status publishing. Credential templates use a bounded subset rather than full Jinja2. See docs/MQTT.md.",
    ),
    "server.webcams.test": (
        S_FULL,
        "Resolves relative URLs against the routed public address, rewrites local wildcard listeners to loopback, and probes only the snapshot URL. DNS and snapshot requests use joined two-second deadlines outside Core.",
    ),
    "component:printer": (
        S_FULL,
        "Proxies requests to Klippy when connected and returns the disconnected error shape otherwise.",
    ),
}


def classify_extra(name: str, remote_names: set[str]) -> str:
    """Classify a phobos JSON-RPC method that isn't in the static baseline list."""
    last = name.rsplit(".", 1)[-1]
    if name in remote_names or last in remote_names:
        return "Klipper remote method (also exposed as JSON-RPC)"
    if name.startswith("printer."):
        return "Klipper-proxied (is_remote) endpoint"
    return "phobos-internal shim"


def _status_for(keys: list[str], implemented: bool) -> tuple[str, str]:
    if not implemented:
        return (S_MISSING, "Not yet implemented in phobos.")
    for k in keys:
        if k in DELTAS:
            return DELTAS[k]
    return (S_FULL, MATCHES)


def _md_escape(s: str) -> str:
    return s.replace("|", "\\|")


def _table(headers: list[str], rows: list[list[str]]) -> str:
    out = [
        "| " + " | ".join(headers) + " |",
        "|" + "|".join("---" for _ in headers) + "|",
    ]
    for r in rows:
        out.append("| " + " | ".join(_md_escape(c) for c in r) + " |")
    return "\n".join(out)


def generate(baseline: dict[str, Any], phobos: dict[str, Any]) -> str:
    # phobos-implemented sets
    ph_paths: set[str] = {
        e["path"].rstrip("/") or "/" for e in phobos.get("endpoints", [])
    }
    ph_methods: set[str] = set()
    for m in phobos.get("jsonrpc_methods", []):
        ph_methods.add(m if isinstance(m, str) else m.get("method", ""))
    ph_notifs: set[str] = set()
    for n in phobos.get("notifications", []):
        ph_notifs.add(n if isinstance(n, str) else n.get("name", ""))

    s = baseline.get("summary", {})
    lines: list[str] = []
    lines.append("# phobos API Coverage")
    lines.append("")
    lines.append(
        "Per-call implementation status of every Moonraker API surface element, "
        "with any behavioural difference. **Auto-generated** "
        "(`PYTHONPATH=tools uv run python -m api_scanner table`) from the Moonraker baseline "
        "(`api/api_surface.json`) × phobos `--dump-api` × curated deltas. "
        "Do not hand-edit; update the deltas in `tools/api_scanner/table.py`."
    )
    lines.append("")
    lines.append(
        f"- Moonraker baseline: `{s.get('moonraker_version', '?')}` "
        f"(commit `{str(s.get('moonraker_commit', ''))[:12]}`)."
    )
    lines.append(
        f"- Endpoints: {s.get('endpoint_count', '?')} · "
        f"JSON-RPC methods: {s.get('jsonrpc_method_count', '?')} · "
        f"notifications: {s.get('notification_count', '?')} · "
        f"remote methods: {s.get('remote_method_count', '?')}."
    )
    lines.append("")
    lines.append(
        "Status: ✅ Full (no recorded delta) · ⚠️ Partial (known "
        "behavior differences) · 🚫 No-op (deliberate, host-safety) · "
        "❌ Missing. These labels summarize curated differences; name coverage does not prove behavioral conformance."
    )
    lines.append("")

    # --- Endpoints ---------------------------------------------------------
    lines.append("## HTTP endpoints")
    lines.append("")
    rows: list[list[str]] = []
    n_full = n_partial = n_noop = n_missing = 0
    for e in sorted(baseline.get("endpoints", []), key=lambda x: x["path"]):
        path = e["path"]
        comp = e.get("component", "")
        methods = e.get("jsonrpc_methods", [])
        if path == "<dynamic>":
            # Moonraker's runtime endpoint-registration facility (Klipper-
            # registered endpoints). phobos handles these via the is_remote
            # proxy path, not as a fixed --dump-api route.
            status, note = (
                S_FULL,
                "Dynamic endpoint registration: Klipper-registered endpoints are proxied via the is_remote path, not a fixed route.",
            )
        else:
            impl = (path.rstrip("/") or "/") in ph_paths
            keys = [path] + list(methods) + [f"path:{path}", f"component:{comp}"]
            status, note = _status_for(keys, impl)
        if status == S_FULL:
            n_full += 1
        elif status == S_PARTIAL:
            n_partial += 1
        elif status == S_NOOP:
            n_noop += 1
        else:
            n_missing += 1
        rows.append(
            [
                f"`{path}`",
                ", ".join(e.get("request_types", [])),
                ", ".join(e.get("transports", [])),
                comp,
                status,
                note,
            ]
        )
    lines.append(
        _table(["Path", "Verbs", "Transports", "Component", "Status", "Notes"], rows)
    )
    lines.append("")
    lines.append(
        f"_Endpoints: {n_full} full, {n_partial} partial, {n_noop} no-op, {n_missing} missing._"
    )
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
        rows.append(
            [f"`{name}`", ", ".join(m.get("transports", [])), comp, status, note]
        )
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
    base_methods: set[str] = {m["method"] for m in baseline.get("jsonrpc_methods", [])}
    base_notifs: set[str] = {n["name"] for n in baseline.get("notifications", [])}
    remote_names: set[str] = {
        r.get("name", "") for r in baseline.get("remote_methods", [])
    }

    extra_methods = sorted(m for m in ph_methods if m and m not in base_methods)
    extra_notifs = sorted(n for n in ph_notifs if n and n not in base_notifs)
    if extra_methods or extra_notifs:
        lines.append("## phobos methods/notifications beyond the static baseline")
        lines.append("")
        lines.append(
            "Calls phobos registers that the static baseline lists don't enumerate. "
            "Most are Moonraker functionality registered via remote methods or the "
            "dynamic is_remote path; genuine phobos-only items are marked "
            '"phobos-internal shim".'
        )
        lines.append("")
        if extra_methods:
            lines.append(
                _table(
                    ["JSON-RPC method", "Classification"],
                    [
                        [f"`{m}`", classify_extra(m, remote_names)]
                        for m in extra_methods
                    ],
                )
            )
            lines.append("")
        if extra_notifs:
            lines.append(
                _table(
                    ["Notification", "Classification"],
                    [[f"`{n}`", "phobos-internal"] for n in extra_notifs],
                )
            )
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
