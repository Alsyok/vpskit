#!/usr/bin/env python3
from pathlib import Path
import hashlib
root=Path(__file__).resolve().parents[1]
files=[root/'vpskit.sh',root/'VERSION',root/'README.md']
for folder in ('lib','modules','installers'):
 files += [p for p in sorted((root/folder).iterdir()) if p.suffix in ('.sh','.py') and p.is_file()]
(root/'manifest.sha256').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.relative_to(root).as_posix()+'\n' for p in files))
print('manifest.sha256 已更新。')
