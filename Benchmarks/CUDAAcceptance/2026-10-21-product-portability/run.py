"""Preserve failure state without restarting any possibly live process."""
import json,runpy
from pathlib import Path
try:runpy.run_path('/private/tmp/bombcad-product-portability/study.py',run_name='__main__')
except BaseException as error:
 p=Path('/Volumes/StudioData/bombcad/experiments/2026-10-21-product-portability-v4/study.json')
 d=json.loads(p.read_text()) if p.exists() else {}
 d.update(status='failed',error=repr(error));p.write_text(json.dumps(d,indent=2)+'\n')
 raise
