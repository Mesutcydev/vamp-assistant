#!/usr/bin/env python3
"""Embed the verified compatibility servers, then Developer ID sign their code."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess


def embed(source, destination, identity):
    manifest = json.loads((source / 'manifest.json').read_text())
    if manifest.get('version') != 1:
        raise RuntimeError('Unsupported runtime manifest')
    compatible = [r for r in manifest['runtimes'] if r['kind'] == 'llamaCompatibility']
    upstream = next((r for r in compatible if 'lfm3' in r.get('architectures', [])), None)
    prism = next((r for r in compatible if 143 in r.get('fileTypes', [])), None)
    if upstream is None or prism is None or upstream is prism:
        raise RuntimeError('The release needs both upstream and Prism compatibility servers')
    entries = [prism, upstream]
    if not identity or identity == '-':
        raise RuntimeError('Embedded runtimes require a Developer ID signing identity')
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True)
    for entry in entries:
        relative = Path(entry['executable'])
        binary = (source / relative).resolve()
        if relative.is_absolute() or '..' in relative.parts or not binary.is_relative_to(source.resolve()):
            raise RuntimeError('Runtime executable escapes the verified staging directory')
        target = destination / relative.parent
        target.mkdir(parents=True, exist_ok=True)
        # Preserve the shared-library aliases and upstream licence. Only the
        # server is needed: TTS, audio and video APIs live in llama-server.
        for item in binary.parent.iterdir():
            if not (item.name == 'llama-server' or '.dylib' in item.name
                    or item.suffix == '.metallib' or item.name.startswith('LICENSE')):
                continue
            output = target / item.name
            if item.is_symlink():
                if '/' in str(item.readlink()):
                    raise RuntimeError('Unexpected library alias')
                output.symlink_to(item.readlink())
            else:
                shutil.copy2(item, output)
        files = [p for p in target.iterdir() if p.is_file() and not p.is_symlink()
                 and ('.dylib' in p.name or p.name == 'llama-server')]
        for code in sorted(files, key=lambda p: p.name == 'llama-server'):
            subprocess.run(['codesign', '--force', '--sign', identity, '--options', 'runtime',
                            '--timestamp', str(code)], check=True)
            subprocess.run(['codesign', '--verify', '--strict', str(code)], check=True)
        subprocess.run([str(destination / relative), '--version'], check=True)
    (destination / 'manifest.json').write_text(json.dumps({'version': 1, 'runtimes': entries}, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--destination', type=Path, required=True)
    parser.add_argument('--identity', required=True)
    args = parser.parse_args()
    embed(args.source, args.destination, args.identity)
