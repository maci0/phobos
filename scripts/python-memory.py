"""Print resident memory after importing the standard-library baseline modules."""

import asyncio
import json
import logging
import os
import sqlite3
import sys
from pathlib import Path


def main() -> None:
    # Keep these modules loaded to match the documented interpreter baseline.
    modules = (asyncio, json, logging, sqlite3)
    assert modules
    status = Path(f"/proc/{os.getpid()}/status").read_text()
    rss = next(line for line in status.splitlines() if line.startswith("VmRSS:"))
    print(f"Python {sys.version.split()[0]} stdlib baseline {rss}")


if __name__ == "__main__":
    main()
