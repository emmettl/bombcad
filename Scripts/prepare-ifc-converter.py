#!/usr/bin/env python3
"""Fetch a checksum-pinned official IfcConvert into the ignored build cache."""
import hashlib
import io
import json
import platform
from pathlib import Path
import urllib.request
import zipfile

root = Path(__file__).resolve().parent.parent
manifest = json.loads((root / "Support/IFC/converter.json").read_text())
archive = manifest["archives"].get(platform.machine())
if archive is None:
    raise SystemExit("IFC conversion supports macOS arm64 and x86_64 builds.")
cache = root / ".build/ifc-converter"
cache.mkdir(parents=True, exist_ok=True)
executable = cache / "IfcConvert"
stamp = cache / "archive-sha256"
try:
    saved = json.loads(stamp.read_text())
    ready = (saved["archive"] == archive["sha256"] and executable.is_file()
             and hashlib.sha256(executable.read_bytes()).hexdigest() == saved["executable"])
except (OSError, ValueError, KeyError):
    ready = False
if not ready:
    with urllib.request.urlopen(archive["url"], timeout=60) as response:
        data = response.read(80_000_001)
    if len(data) > 80_000_000 or hashlib.sha256(data).hexdigest() != archive["sha256"]:
        raise SystemExit("IFC converter download failed its size/checksum check.")
    with zipfile.ZipFile(io.BytesIO(data)) as package:
        binary = package.read("IfcConvert")
    temporary = cache / "IfcConvert.download"
    temporary.write_bytes(binary)
    temporary.chmod(0o755)
    temporary.replace(executable)
    stamp.write_text(json.dumps({"archive": archive["sha256"],
                                 "executable": hashlib.sha256(binary).hexdigest()}) + "\n")
print(executable)
