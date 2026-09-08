#!/usr/bin/env python3
"""Download pinned, data-only model files for an isolated local evaluation."""
import hashlib
import json
from pathlib import Path
import sys
import urllib.request
import time
from concurrent.futures import ThreadPoolExecutor

manifest = json.loads(Path(sys.argv[1]).read_text())
root = Path.home() / 'Library/Application Support/LocalFlow/ModelExperiments'
def download(item):
    destination = root / item['repo'].split('/')[-1]
    print('Downloading', item['repo'], item['revision'], flush=True)
    for f in item['files']:
        path = destination / f['rfilename']
        if path.exists() and path.stat().st_size == f['size']: continue
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_suffix(path.suffix + '.partial')
        offset = temporary.stat().st_size if temporary.exists() else 0
        url = "https://huggingface.co/" + item['repo'] + "/resolve/" + item['revision'] + "/" + f['rfilename']
        request = urllib.request.Request(url, headers={'Range': f'bytes={offset}-'} if offset else {})
        with urllib.request.urlopen(request, timeout=60) as response:
            append = offset > 0 and response.status == 206
            if append and not response.headers.get('Content-Range', '').startswith(f'bytes {offset}-'):
                raise RuntimeError('Unexpected resumed range')
            if not append: offset = 0
            last = time.monotonic()
            with temporary.open('ab' if append else 'wb') as output:
                while data := response.read(4*1024*1024):
                    output.write(data); offset += len(data)
                    if time.monotonic() - last > 10:
                        print(f['rfilename'], round(offset / f['size'] * 100), '%', flush=True)
                        last = time.monotonic()
        temporary.replace(path)
    for f in item['files']:
        path = destination / f['rfilename']
        assert path.stat().st_size == f['size'], str(path)
        sha = hashlib.sha256() if 'lfs' in f else hashlib.sha1()
        if 'lfs' not in f:
            sha.update(f"blob {f['size']}\0".encode())
        with path.open('rb') as stream:
            for data in iter(lambda: stream.read(4*1024*1024), b''):
                sha.update(data)
        assert sha.hexdigest() == (f['lfs']['sha256'] if 'lfs' in f else f['blobId']), str(path)
    (destination / '.verified').write_text(item['revision'])
    print('Verified', destination, flush=True)

with ThreadPoolExecutor(max_workers=2) as pool:
    list(pool.map(download, manifest))
