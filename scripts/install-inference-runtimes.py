#!/usr/bin/env python3
"""Install pinned optional runtimes without changing Homebrew or the app's MLX ABI.

Requires Apple Silicon, Xcode, git, cmake and uv. No model is selected, no service
is installed, and existing runtime entries/settings are preserved. The Bonsai
checkpoint is optional and currently needs a Mac with at least 24 GB RAM.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
DEST = Path.home() / 'Library/Application Support/BeetCode/Runtimes'
BUILD = Path.home() / 'Library/Caches/VampRuntimeBuilds'
PINS = {
    'omlx': ('https://github.com/jundot/omlx.git', 'f0d8428acd3220c364177d1ea9593e4e15f94107', 'omlx-f0d8428'),
    'mlxfast': ('https://github.com/Layr-Labs/mlxfast-bonsai2-27b-engine.git', '831fae740de35a106e85768d8b0534b4af422b13', 'mlxfast-831fae7'),
    'llamaMetal': ('https://github.com/ggml-org/llama.cpp.git', '7fe450e19305b828c199d602c23a8337aaa1f03b', 'llama-metal-v0.5.0'),
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


def install(kind, with_weights):
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
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', choices=[*PINS, 'all'], default='all')
    parser.add_argument('--bonsai-weights', action='store_true', help='Also download the pinned Bonsai pack; requires 24 GB RAM and 22 GiB free disk')
    args = parser.parse_args()
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        parser.error('These runtimes require an Apple Silicon Mac.')
    DEST.mkdir(parents=True, exist_ok=True); BUILD.mkdir(parents=True, exist_ok=True)
    path = DEST / 'manifest.json'
    manifest = json.loads(path.read_text()) if path.exists() else {'version': 1, 'runtimes': []}
    if manifest.get('version') != 1: raise RuntimeError('Unknown existing runtime manifest version')
    for kind in PINS if args.runtime == 'all' else [args.runtime]:
        entry = install(kind, args.bonsai_weights)
        manifest['runtimes'] = [r for r in manifest['runtimes'] if r['kind'] != kind] + [entry]
        temporary = path.with_suffix('.json.pending')
        temporary.write_text(json.dumps(manifest, indent=2) + '\n'); temporary.replace(path)
    print('Installed. Enable a compatible runtime in Vamp Settings → Agent and reload the model.')


if __name__ == '__main__':
    main()
