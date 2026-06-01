import os
import sys

# Make the ``api_scanner`` package importable when tests are run directly
# (pytest from the repo root or from tools/).
_TOOLS = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
if _TOOLS not in sys.path:
    sys.path.insert(0, _TOOLS)
