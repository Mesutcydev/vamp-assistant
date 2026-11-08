#!/usr/bin/env python3
"""Install pinned runtimes without changing Homebrew or the app's MLX ABI.

Requires Apple Silicon. Source-built runtimes also need Xcode, git, cmake and uv.
No model is selected, no service is installed, and existing runtime entries and
settings are preserved. Use --runtime compatible for current GGUF runtimes.
Experimental Bonsai MLXFast weights currently need at least 24 GB RAM.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import posixpath
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
DEST = Path.home() / 'Library/Application Support/BeetCode/Runtimes'
BUILD = Path.home() / 'Library/Caches/VampRuntimeBuilds'
PINS = {
    'omlx': ('https://github.com/jundot/omlx.git', 'f0d8428acd3220c364177d1ea9593e4e15f94107', 'omlx-f0d8428'),
    'mlxfast': ('https://github.com/Layr-Labs/mlxfast-bonsai2-27b-engine.git', '831fae740de35a106e85768d8b0534b4af422b13', 'mlxfast-831fae7'),
    'llamaMetal': ('https://github.com/ggml-org/llama.cpp.git', '7fe450e19305b828c199d602c23a8337aaa1f03b', 'llama-metal-v0.5.0'),
}
# v0.9.0 points to the reproducible b12110 binary release.
RELEASES = {
    'llamaCompatibility': dict(
        repo='ggml-org/llama.cpp', build='b12110',
        sha256='4f5b8de12e0b9516658ca6a5764c6ffb3d7c659c3dd538556b1413c7b4050662',
        architectures=['llama', 'llama4', 'qwen', 'qwen2', 'qwen2moe', 'qwen2vl',
                       'qwen3', 'qwen3moe', 'qwen3next', 'qwen3vl', 'qwen3vlmoe',
                       'qwen35', 'qwen35moe', 'qwen4exp', 'qwen3tts', 'rwkv6qwen2',
                       'lfm2', 'lfm2moe', 'lfm3']),
    'llamaPrism': dict(
        repo='PrismML-Eng/llama.cpp', build='prism-b12128-d7b2896',
        sha256='7072bcece7b2ae5cc97db85b65f4a57d96a4f1b926555bc97cf48d6357b3e532',
        fileTypes=[141, 142, 143]),
}


def run(args, cwd=None, env=None):
    subprocess.run([str(x) for x in args], cwd=cwd, env=env, check=True)


def checkout(kind):
    remote, revision, folder = PINS[kind]
    source = BUILD / folder
    if not source.exists():
        run(['git', 'clone', '--filter=blob:none', '--no-checkout', remote, source],
            env=dict(os.environ, GIT_LFS_SKIP_SMUDGE='1'))
        run(['git', 'checkout', '--detach', revision], cwd=source,
            env=dict(os.environ, GIT_LFS_SKIP_SMUDGE='1'))
    actual = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=source, text=True).strip()
    if actual != revision:
        raise RuntimeError(f'{source} is at another revision; move it aside before installing')
    return source, DEST / folder


def copy(source, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    if source.is_symlink():
        if target.exists() or target.is_symlink(): target.unlink()
        target.symlink_to(source.readlink().name)
    elif source.is_dir():
        shutil.copytree(source, target, dirs_exist_ok=True)
    else:
        temporary = target.with_name(target.name + '.installing')
        shutil.copy2(source, temporary)
        temporary.replace(target)


def sha256_file(handle):
    digest = hashlib.sha256()
    for chunk in iter(lambda: handle.read(1024 * 1024), b''):
        digest.update(chunk)
    return digest.hexdigest()


def validate_archive_member(member, build):
    """Reject paths and links that could escape the expected release folder."""
    name = member.name.rstrip('/')
    if name == '.' and member.isdir():
        return
    root = f'llama-{build}'
    if (not name or name.startswith('/') or posixpath.normpath(name) != name
            or not (name == root or name.startswith(root + '/'))):
        raise RuntimeError(f'Unsafe runtime archive path: {member.name}')
    if member.issym():
        link = posixpath.normpath(posixpath.join(posixpath.dirname(name), member.linkname))
        if member.linkname.startswith('/') or not link.startswith(root + '/'):
            raise RuntimeError(f'Unsafe runtime archive link: {member.name}')
    elif not (member.isfile() or member.isdir()):
        raise RuntimeError(f'Unsupported runtime archive entry: {member.name}')


def verify_runtime_tree(archive, directory, build):
    for member in archive.getmembers():
        validate_archive_member(member, build)
        if member.name == '.':
            continue
        path = directory / member.name
        if not path.resolve().is_relative_to(directory.resolve()):
            raise RuntimeError(f'Runtime path escapes its installation: {path}')
        if member.isdir():
            valid = path.is_dir() and not path.is_symlink()
        elif member.issym():
            valid = path.is_symlink() and os.readlink(path) == member.linkname
        else:
            valid = path.is_file() and not path.is_symlink()
            if valid:
                with path.open('rb') as installed, archive.extractfile(member) as original:
                    valid = sha256_file(installed) == sha256_file(original)
        if not valid:
            raise RuntimeError(f'Existing runtime differs from the verified release: {path}')


def install_compatibility(kind):
    """Install a checksum-verified official release in this app's directory."""
    release = RELEASES[kind]
    build = release['build']
    name = f'llama-{build}-bin-macos-arm64.tar.gz'
    url = f"https://github.com/{release['repo']}/releases/download/{build}/{name}"
    target = DEST / f'llama-{build}'
    if target.is_symlink():
        raise RuntimeError(f'Refusing to install through a runtime symlink: {target}')
    with tempfile.TemporaryDirectory(prefix='.compatibility-install-', dir=DEST) as scratch:
        scratch = Path(scratch)
        archive_path = scratch / name
        request = urllib.request.Request(url, headers={'User-Agent': 'Vamp-runtime-installer'})
        with urllib.request.urlopen(request, timeout=60) as response, archive_path.open('wb') as output:
            shutil.copyfileobj(response, output)
        with archive_path.open('rb') as handle:
            if sha256_file(handle) != release['sha256']:
                raise RuntimeError(f'The {build} runtime checksum did not match the pinned release.')
        with tarfile.open(archive_path, 'r:gz') as archive:
            for member in archive.getmembers():
                validate_archive_member(member, build)
            if target.exists():
                verify_runtime_tree(archive, target, build)
            else:
                staging = scratch / 'runtime'
                staging.mkdir()
                if hasattr(tarfile, 'data_filter'):
                    archive.extractall(staging, filter='data')
                else:
                    archive.extractall(staging)
                verify_runtime_tree(archive, staging, build)
                staging.rename(target)
    executable = target / f'llama-{build}/llama-server'
    if not os.access(executable, os.X_OK):
        raise RuntimeError(f'The verified runtime is not executable: {executable}')
    return dict(kind='llamaCompatibility', revision=build,
                executable=str(executable.relative_to(DEST)), models=[], visionModels=[],
                architectures=release.get('architectures', []),
                fileTypes=release.get('fileTypes', []))


def install(kind, with_weights):
    if kind in RELEASES:
        return install_compatibility(kind)
    source, target = checkout(kind)
    target.mkdir(parents=True, exist_ok=True)
    if kind == 'omlx':
        if not (target / 'venv/bin/python').exists():
            run(['uv', 'venv', '--python', '3.13', target / 'venv'])
        run(['uv', 'pip', 'install', '--python', target / 'venv/bin/python', source,
             'torch==2.14.0', 'torchvision==0.29.0'])
        executable = target / 'venv/bin/omlx'
        models, vision = ['qwen3-0.6b-omlx', 'smolvlm2-500m-mlx'], ['smolvlm2-500m-mlx']
    elif kind == 'mlxfast':
        if with_weights and int(subprocess.check_output(['sysctl', '-n', 'hw.memsize'])) < 24 * 1024**3:
            raise RuntimeError('Bonsai MLXFast currently requires 24 GB RAM. Install its runtime without --bonsai-weights on smaller Macs.')
        patch = ROOT / 'scripts/runtime-patches/mlxfast-vamp.patch'
        applied = subprocess.run(['git', 'apply', '--reverse', '--check', str(patch)], cwd=source,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
        if not applied: run(['git', 'apply', patch], cwd=source)
        copy(ROOT / 'scripts/runtime-sources/VampBonsaiServerEngine.swift',
             source / 'Vendor/mlx-swift-lm/Libraries/MLXLMServer/Runtime/VampBonsaiServerEngine.swift')
        env = dict(os.environ, MLXFAST_SKIP_MACMON_INSTALL='1', MLXFAST_SKIP_DFLASH_DRAFTER='1',
                   MLXFAST_SKIP_MTP_HEAD='1')
        if not with_weights: env['MLXFAST_SKIP_WEIGHTS_DOWNLOAD'] = '1'
        run(['bash', 'setup.sh'], cwd=source, env=env)
        run(['swift', 'build', '-c', 'release', '--scratch-path', '.build-worker', '--product', 'mlx-server', '-j', '4'], cwd=source)
        products = source / '.build-worker/release'
        for name in ['mlx-server', 'mlx.metallib']:
            copy(products / name, target / name)
        for bundle in products.glob('*.bundle'): copy(bundle, target / bundle.name)
        executable = target / 'mlx-server'
        models, vision = ['Ternary-Bonsai-2-27B-MLXFast'], []
    else:
        build = source / 'build-vamp'
        run(['cmake', '-S', source, '-B', build, '-DCMAKE_BUILD_TYPE=Release', '-DGGML_METAL=ON',
             '-DGGML_METAL_EMBED_LIBRARY=ON', '-DLLAMA_BUILD_TESTS=OFF'])
        run(['cmake', '--build', build, '-j', '4', '--target', 'llama-server', 'llama-bench'])
        for file in (build / 'bin').iterdir():
            if file.name in ('llama-server', 'llama-bench') or file.name.endswith('.dylib'):
                copy(file, target / 'bin' / file.name)
        executable = target / 'bin/llama-server'
        models, vision = ['Huihui-Qwen3.8-27B-abliterated-Q2_K'], ['Huihui-Qwen3.8-27B-abliterated-Q2_K']
    copy(source / 'LICENSE', target / 'LICENSE')
    revision = PINS[kind][1] + ('+vamp1' if kind == 'mlxfast' else '')
    return dict(kind=kind, revision=revision, executable=str(executable.relative_to(DEST)),
                models=models, visionModels=vision)


def main():
    global DEST
    parser = argparse.ArgumentParser(description=__doc__)
    kinds = [*PINS, *RELEASES]
    parser.add_argument('--runtime', choices=[*kinds, 'compatible', 'all'], default='compatible')
    parser.add_argument('--destination', type=Path, help='Explicit runtime directory for release preparation')
    parser.add_argument('--bonsai-weights', action='store_true', help='Also download the pinned Bonsai pack; requires 24 GB RAM and 22 GiB free disk')
    args = parser.parse_args()
    if args.destination is not None:
        DEST = args.destination.expanduser().resolve()
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        parser.error('These runtimes require an Apple Silicon Mac.')
    DEST.mkdir(parents=True, exist_ok=True); BUILD.mkdir(parents=True, exist_ok=True)
    path = DEST / 'manifest.json'
    manifest = json.loads(path.read_text()) if path.exists() else {'version': 1, 'runtimes': []}
    if manifest.get('version') != 1: raise RuntimeError('Unknown existing runtime manifest version')
    selected = kinds if args.runtime == 'all' else list(RELEASES) if args.runtime == 'compatible' else [args.runtime]
    for kind in selected:
        entry = install(kind, args.bonsai_weights)
        if kind in RELEASES:
            # Keep unrelated and older compatibility entries for rollback.
            manifest['runtimes'] = [entry] + [r for r in manifest['runtimes']
                if not (r['kind'] == entry['kind'] and r['executable'] == entry['executable'])]
        else:
            manifest['runtimes'] = [r for r in manifest['runtimes'] if r['kind'] != kind] + [entry]
        temporary = path.with_suffix('.json.pending')
        temporary.write_text(json.dumps(manifest, indent=2) + '\n'); temporary.replace(path)
    print('Installed. Model compatibility runtimes are selected automatically; experimental runtimes can be enabled in Settings → Agent.')


if __name__ == '__main__':
    main()
