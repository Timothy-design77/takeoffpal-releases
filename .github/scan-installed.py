import json
from pathlib import Path
import re
import sys
import zipfile

root = Path(sys.argv[1])
hits = []
for path in sorted(root.rglob('*')):
    if not path.is_file():
        continue
    relative = path.relative_to(root).as_posix()
    entries = [(relative, path.read_bytes())]
    if zipfile.is_zipfile(path):
        with zipfile.ZipFile(path) as archive:
            entries.extend((relative + '!' + name, archive.read(name)) for name in archive.namelist())
    for name, data in entries:
        count = len(re.findall(rb'primo|mccormick', data, re.I))
        if count:
            hits.append({'file': name, 'matches': count})
print(json.dumps({'installed_root': str(root), 'matching_files': len(hits), 'hits': hits}, indent=2))
print('Strict installed-content name check: ' + ('FAIL' if hits else 'PASS'))
