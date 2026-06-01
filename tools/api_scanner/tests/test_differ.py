"""Tests for the diff logic and report rendering."""

from api_scanner import differ


def _endpoint(path, verbs, **kw):
    e = {
        "path": path, "request_types": verbs, "transports": ["HTTP"],
        "wrap_result": True, "content_type": None, "auth_required": True,
        "is_remote": False, "debug_only": False, "component": "x",
        "source": "x.py:1", "jsonrpc_methods": [], "multi_verb": False,
    }
    e.update(kw)
    return e


def _scan(endpoints=None, rpc=None, remote=None, notif=None, static=None):
    return {
        "summary": {},
        "endpoints": endpoints or [],
        "jsonrpc_methods": rpc or [],
        "remote_methods": remote or [],
        "notifications": notif or [],
        "static_handlers": static or [],
    }


def test_identical_scans_no_drift():
    base = _scan(endpoints=[_endpoint("/server/info", ["GET"])])
    d = differ.diff(base, base)
    assert differ.has_drift(d) is False
    assert "No API drift" in differ.render(d)


def test_added_endpoint():
    base = _scan(endpoints=[_endpoint("/server/info", ["GET"])])
    cur = _scan(endpoints=[
        _endpoint("/server/info", ["GET"]),
        _endpoint("/server/new", ["POST"]),
    ])
    d = differ.diff(base, cur)
    assert differ.has_drift(d) is True
    assert "/server/new [POST]" in d["endpoints"]["added"]
    assert "ADDED" in differ.render(d)


def test_removed_endpoint():
    base = _scan(endpoints=[
        _endpoint("/server/info", ["GET"]),
        _endpoint("/server/old", ["GET"]),
    ])
    cur = _scan(endpoints=[_endpoint("/server/info", ["GET"])])
    d = differ.diff(base, cur)
    assert "/server/old [GET]" in d["endpoints"]["removed"]
    assert differ.has_drift(d) is True


def test_changed_endpoint_field():
    base = _scan(endpoints=[_endpoint("/server/info", ["GET"], auth_required=True)])
    cur = _scan(endpoints=[_endpoint("/server/info", ["GET"], auth_required=False)])
    d = differ.diff(base, cur)
    changed = d["endpoints"]["changed"]
    assert len(changed) == 1
    assert changed[0]["fields"]["auth_required"] == {"old": True, "new": False}
    assert "CHANGED" in differ.render(d)


def test_source_move_is_not_drift():
    base = _scan(endpoints=[_endpoint("/server/info", ["GET"], source="a.py:1")])
    cur = _scan(endpoints=[_endpoint("/server/info", ["GET"], source="b.py:9")])
    d = differ.diff(base, cur)
    assert differ.has_drift(d) is False


def test_notification_diff():
    base = _scan(notif=[{"name": "notify_a", "event_name": None,
                         "component": "x", "source": "x.py:1"}])
    cur = _scan(notif=[{"name": "notify_b", "event_name": None,
                        "component": "x", "source": "x.py:1"}])
    d = differ.diff(base, cur)
    assert d["notifications"]["added"] == ["notify_b"]
    assert d["notifications"]["removed"] == ["notify_a"]
    assert differ.has_drift(d) is True


def test_method_diff():
    base = _scan(rpc=[{"method": "server.info"}])
    cur = _scan(rpc=[{"method": "server.info"}, {"method": "server.config"}])
    d = differ.diff(base, cur)
    assert d["jsonrpc_methods"]["added"] == ["server.config"]
