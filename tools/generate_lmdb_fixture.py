#!/usr/bin/env python3
"""Generate a minimal Moonraker-compatible data.mdb fixture for lmdb drop-in testing.

The on-disk format matches Moonraker's legacy LMDB provider (database.py):
  - main (unnamed) DB: namespace name → dbi pointer (one entry per namespace)
  - each namespace is a named database
  - records are encoded: int='q'+i64(LE), float='d'+f64(LE), bool='?'+0/1,
    str='s'+raw, list/dict=JSON, null=\x00
"""

import json
import os
import struct
import sys

import lmdb


def encode_value(val):
    """Encode a Python value into Moonraker's record byte format."""
    if val is None:
        return b'\x00'
    if isinstance(val, bool):
        return b'?' + (b'\x01' if val else b'\x00')
    if isinstance(val, int):
        return b'q' + struct.pack('q', val)
    if isinstance(val, float):
        return b'd' + struct.pack('d', val)
    if isinstance(val, str):
        return b's' + val.encode('utf-8')
    # list or dict → raw JSON
    return json.dumps(val).encode('utf-8')


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else "vendor/moonraker/tests/assets/database"
    os.makedirs(outdir, exist_ok=True)

    env = lmdb.open(outdir, map_size=200 * 1024 * 1024, max_dbs=100)

    # Sample namespaces and records matching what Moonraker stores
    namespaces = {
        "moonraker": {
            "server.port": 7125,
            "server.host": "0.0.0.0",
            "server.ssl": False,
            "update_manager.enable_auto_refresh": True,
        },
        "history": {
            "jobs.count": 0,
        },
        "webcams": {},
    }

    with env.begin(write=True) as txn:
        for ns_name, records in namespaces.items():
            ns_name_bytes = ns_name.encode('utf-8')
            # Open or create the named database
            db = env.open_db(ns_name_bytes, txn=txn, create=True)
            # Store namespace reference in main DB
            txn.put(ns_name_bytes, b'', db=db)

            with txn.cursor(db=db) as cur:
                if not cur.first():
                    # Empty db — add sample records
                    for key, val in records.items():
                        txn.put(key.encode('utf-8'), encode_value(val), db=db)

    env.close()
    print(f"Fixture created at {outdir}/data.mdb")


if __name__ == "__main__":
    main()
