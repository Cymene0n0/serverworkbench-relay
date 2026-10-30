#!/usr/bin/env python3
"""Refresh or verify bootstrap payload pins from reviewed, exact file bytes."""
import argparse
import hashlib
from pathlib import Path
import re

parser = argparse.ArgumentParser()
parser.add_argument('--check', action='store_true')
parser.add_argument('--ref', help='immutable Git commit SHA for the core payload')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
file = root / 'install.sh'
text = file.read_text(encoding='utf-8')
paths = ('relay.sh', 'lib/common.sh', 'lib/pins.sh')
lines = []
for path in paths:
    payload = (root / path).read_bytes()
    if b'\r' in payload:
        raise SystemExit(f'{path}: normalize line endings to LF before pinning')
    digest = hashlib.sha256(payload).hexdigest()
    lines.append(f"verify_file '{path}' '{digest}'")
pattern = r'(?<=# BEGIN PAYLOAD PINS -- regenerated from reviewed repository files.\n).*?(?=# END PAYLOAD PINS)'
updated, count = re.subn(pattern, '\n'.join(lines)+'\n', text, flags=re.S)
if count != 1:
    raise SystemExit('Cannot uniquely identify bootstrap payload manifest')
if args.ref:
    if not re.fullmatch('[0-9a-f]{40}', args.ref):
        raise SystemExit('--ref must be a full lowercase 40-character Git commit SHA')
    updated, count = re.subn(r"^readonly CORE_REF='[^']+'$", f"readonly CORE_REF='{args.ref}'", updated, flags=re.M)
    if count != 1:
        raise SystemExit('Cannot uniquely identify CORE_REF')
if args.check:
    if updated != text:
        raise SystemExit('Bootstrap pins are stale; run python3 tools/update-bootstrap-pins.py')
    print('PASS bootstrap payload SHA256 pins')
else:
    file.write_text(updated, encoding='utf-8', newline='\n')
    print('Updated bootstrap payload SHA256 pins')
