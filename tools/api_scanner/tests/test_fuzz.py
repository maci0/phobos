"""Fuzz-style robustness tests.

Feed the extractor syntactically valid but weird / malformed Python and assert
it never crashes and degrades gracefully to ``<dynamic>`` or to skipping.
"""

import random
import string

import pytest

from api_scanner.extractor import DYNAMIC, extract_from_source

WEIRD_SOURCES = [
    # syntax error -> skipped, empty result
    "def (:::\n    register_endpoint(",
    # endpoint path is a call result
    "self.server.register_endpoint(make_path(), RequestType.GET, cb)\n",
    # request type is a function call
    "self.server.register_endpoint('/server/x', get_types(), cb)\n",
    # transports built from a list comprehension
    "self.server.register_endpoint('/server/x', RequestType.GET, cb,\n"
    "    transports=[t for t in types])\n",
    # f-string path
    "self.server.register_endpoint(f'/server/{x}', RequestType.GET, cb)\n",
    # deeply nested / starred args
    "self.server.register_endpoint(*args, **kwargs)\n",
    # wrap_result is a variable, not a literal bool
    "self.server.register_endpoint('/server/x', RequestType.GET, cb,\n"
    "    wrap_result=flag)\n",
    # register_remote_method with non-literal name
    "self.server.register_remote_method(name_var, cb)\n",
    # notification with a computed event name
    "self.server.register_notification('a:' + suffix)\n",
    # empty call
    "register_endpoint()\n",
    # unicode identifiers and strings
    "self.server.register_endpoint('/server/ünïcödé', RequestType.GET, cb)\n",
]


@pytest.mark.parametrize("src", WEIRD_SOURCES)
def test_weird_sources_do_not_crash(src):
    v = extract_from_source(src, "components/weird.py", source_root=".")
    # whatever it extracted, the structures must be well-formed
    for e in v.endpoints:
        assert isinstance(e.path, str)
        assert isinstance(e.request_types, list)
        assert isinstance(e.transports, list)
    for r in v.remote_methods:
        assert isinstance(r.name, str)


def test_dynamic_path_is_sentinel():
    src = "self.server.register_endpoint(make_path(), RequestType.GET, cb)\n"
    v = extract_from_source(src, "components/weird.py", source_root=".")
    assert v.endpoints[0].path == DYNAMIC


def test_syntax_error_yields_empty():
    v = extract_from_source("def (:::\n", "x.py", source_root=".")
    assert v.endpoints == []
    assert v.notifications == []


def test_random_garbage_never_raises():
    rng = random.Random(1234)
    alphabet = string.printable
    for _ in range(200):
        n = rng.randint(0, 80)
        blob = "".join(rng.choice(alphabet) for _ in range(n))
        # must not raise regardless of content
        extract_from_source(blob, "components/garbage.py", source_root=".")


def test_register_endpoint_wrapped_in_random_context():
    # register_endpoint buried in odd-but-valid constructs
    src = (
        "x = [self.server.register_endpoint('/server/a', RequestType.GET, cb)\n"
        "     for _ in range(3)]\n"
        "with ctx():\n"
        "    self.server.register_endpoint('/server/b', RequestType.POST, cb)\n"
    )
    v = extract_from_source(src, "components/odd.py", source_root=".")
    paths = sorted(e.path for e in v.endpoints)
    assert paths == ["/server/a", "/server/b"]
