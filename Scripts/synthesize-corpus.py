#!/usr/bin/env python3
"""Synthetic smoke corpus; not a substitute for the owner's real speech."""
import json, subprocess
from pathlib import Path
root=Path(__file__).resolve().parent.parent
output=root/'build.noindex/evaluation'
output.mkdir(parents=True,exist_ok=True)
items=json.loads((root/'docs/evaluation-corpus.json').read_text())
for item in items:
 file=output/(item['id']+'.aiff')
 if not file.exists(): subprocess.run(['say','-v','Milena','-r','180','-o',str(file),item['text']],check=True)
 item['audio']=str(file)
(output/'manifest.json').write_text(json.dumps(items,ensure_ascii=False,indent=2))
print(output/'manifest.json')
