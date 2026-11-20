#!/usr/bin/env python3
#
# build_db.py - base de datos del Downloader de MiSTer para la Chameleon96
#
# Genera db.json.zip con db_id "distribution_mister": en la SD de la ch96,
# downloader.ini apunta [distribution_mister] a este fichero, así que el
# Downloader oficial (Scripts/update.sh) instala desde aquí en vez de desde
# MiSTer-devel/Distribution_MiSTer:
#
#   - cores: sources.ini, el último releases/*_ch96_AAAAMMDD.rbf de cada repo
#   - scripts de MiSTer: sección [oficial] de sources.ini (wifi.sh...)
#   - menu.rbf
#   - MiSTer: system.json (lo escribe tools/build_release.sh)
#   - linux:  linux.json  (paquete release_ch96: kernel, U-Boot y linux.img)
#
# Los .rbf no se copian: la URL apunta al repositorio de origen, fijada al
# commit (raw.githubusercontent.com/<repo>/<sha>/releases/<fichero>).
#
# Uso: tools/build_db.py [--out db.json.zip] [--db-url URL]
#
# Solo usa git y la biblioteca estándar de Python (sin API de GitHub).
#
# Autor: Shaeon (Carlos Palmero)

import argparse
import configparser
import fnmatch
import hashlib
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DB_ID = 'distribution_mister'
DEFAULT_DB_URL = 'https://raw.githubusercontent.com/shaeon/Distribution_MiSTer_ch96/main/db.json.zip'
OFFICIAL_SECTION = 'oficial'
OFFICIAL_DB_URL = 'https://raw.githubusercontent.com/MiSTer-devel/Distribution_MiSTer/main/db.json.zip'
DATE_RE = re.compile(r'_(\d{8})\.rbf$', re.IGNORECASE)


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def git(*args, cwd=None):
    return subprocess.run(['git', *args], cwd=cwd, check=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout


def latest_release(repo, branch, pattern, work):
    """Clona sin blobs, elige el .rbf más reciente y devuelve (sha, ruta, bytes)."""
    dest = os.path.join(work, repo.replace('/', '__') + '__' + (branch or 'HEAD'))
    if not os.path.isdir(dest):
        cmd = ['clone', '-q', '--depth', '1', '--filter=blob:none', '--no-checkout']
        if branch:
            cmd += ['-b', branch]
        git(*cmd, f'https://github.com/{repo}.git', dest)
    sha = git('rev-parse', 'HEAD', cwd=dest).decode().strip()
    names = git('ls-tree', '--name-only', 'HEAD', 'releases/', cwd=dest).decode().split('\n')
    names = [os.path.basename(n) for n in names if n]
    cands = [n for n in names if fnmatch.fnmatch(n.lower(), pattern.lower()) and DATE_RE.search(n)]
    if not cands:
        raise RuntimeError(f'{repo}: no hay releases/{pattern}')
    best = max(cands, key=lambda n: (DATE_RE.search(n).group(1), n))
    data = git('show', f'HEAD:releases/{best}', cwd=dest)
    return sha, f'releases/{best}', data


def raw_url(repo, sha, path):
    return f'https://raw.githubusercontent.com/{repo}/{sha}/{urllib.parse.quote(path)}'


def install_name(section, filename):
    """TS2068_ch96_20261117.rbf -> TS2068_20261117.rbf"""
    return re.sub(r'_ch96(?=_\d{8}\.rbf$)', '', filename, flags=re.IGNORECASE)


def copy_official(paths, files, folders):
    """Copia entradas tal cual de la base de datos oficial de MiSTer (scripts
    que no dependen de la placa: wifi.sh, samba_on.sh...). La URL queda fijada
    al commit de Distribution_MiSTer que anuncia la base de datos oficial."""
    with urllib.request.urlopen(OFFICIAL_DB_URL, timeout=60) as r:
        z = zipfile.ZipFile(io.BytesIO(r.read()))
    official = json.loads(z.read(z.namelist()[0]))
    base = official.get('base_files_url', '')
    for path in paths:
        desc = official['files'].get(path)
        if desc is None:
            raise RuntimeError(f'{path} no está en la base de datos oficial')
        entry = {'hash': desc['hash'], 'size': desc['size'],
                 'url': desc.get('url') or base + urllib.parse.quote(path)}
        files[path] = entry
        parts = path.split('/')[:-1]
        for i in range(1, len(parts) + 1):
            folders.setdefault('/'.join(parts[:i]), {})
        log(f'  {path:45s} <- MiSTer-devel/Distribution_MiSTer')


def load_json(name):
    path = os.path.join(ROOT, name)
    if not os.path.isfile(path):
        return None
    with open(path) as f:
        return json.load(f)


def build(db_url):
    cfg = configparser.ConfigParser(inline_comment_prefixes=(';', '#'))
    cfg.optionxform = str
    with open(os.path.join(ROOT, 'sources.ini')) as f:
        cfg.read_file(f)

    files, folders = {}, {}
    errors = []

    with tempfile.TemporaryDirectory() as work:
        for section in cfg.sections():
            s = cfg[section]
            if section == OFFICIAL_SECTION:
                try:
                    copy_official(s.get('files', '').split(), files, folders)
                except Exception as e:
                    errors.append(f'[{section}] {e}')
                continue
            repo = s.get('repo')
            if not repo:
                errors.append(f'[{section}] sin repo')
                continue
            pattern = s.get('pattern', f'{section}_ch96_*.rbf')
            try:
                sha, path, data = latest_release(repo, s.get('branch'), pattern, work)
            except Exception as e:  # un core roto no tumba la base de datos
                errors.append(f'[{section}] {e}')
                continue

            target = s.get('target')
            if target:
                dest = target
            else:
                folder = s.get('folder', '_Computer').strip('/')
                dest = f'{folder}/{install_name(section, os.path.basename(path))}'
                parts = folder.split('/')
                for i in range(1, len(parts) + 1):
                    folders.setdefault('/'.join(parts[:i]), {})

            entry = {
                'hash': hashlib.md5(data).hexdigest(),
                'size': len(data),
                'url': raw_url(repo, sha, path),
            }
            if dest == 'menu.rbf':
                entry.update({'path': 'system', 'reboot': True})
            files[dest] = entry
            log(f'  {dest:45s} <- {repo}@{sha[:7]} {path}')

    system = load_json('system.json')
    if system and system.get('MiSTer'):
        m = system['MiSTer']
        files['MiSTer'] = {
            'hash': m['hash'], 'size': m['size'], 'url': m['url'],
            'path': 'system', 'reboot': True,
            'backup': '.MiSTer.old', 'tmp': 'MiSTer.new',
        }
        log(f'  {"MiSTer":45s} <- {m["url"]}')

    db = {
        'v': 1,
        'db_id': DB_ID,
        'db_url': db_url,
        'timestamp': 0,
        'files': dict(sorted(files.items())),
        'folders': dict(sorted(folders.items())),
    }

    linux = load_json('linux.json')
    if linux:
        db['linux'] = {k: linux[k] for k in ('hash', 'size', 'url', 'version')}
        log(f'  {"linux " + linux["version"]:45s} <- {linux["url"]}')

    return db, errors


def read_previous(out):
    try:
        with zipfile.ZipFile(out) as z:
            return json.loads(z.read('db.json'))
    except Exception:
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', default=os.path.join(ROOT, 'db.json.zip'))
    ap.add_argument('--db-url', default=DEFAULT_DB_URL)
    args = ap.parse_args()

    db, errors = build(args.db_url)
    for e in errors:
        log('AVISO: ' + e)

    # Mismo contenido -> mismo fichero (sin commits vacíos cada vez que corre)
    prev = read_previous(args.out)
    if prev is not None:
        prev_ts = prev.get('timestamp', 0)
        prev['timestamp'] = 0
        if prev == db:
            log('Sin cambios.')
            return 0
    db['timestamp'] = int(time.time())

    data = json.dumps(db, indent=1, ensure_ascii=False).encode()
    tmp = args.out + '.tmp'
    with zipfile.ZipFile(tmp, 'w', zipfile.ZIP_DEFLATED) as z:
        info = zipfile.ZipInfo('db.json', date_time=(2020, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        z.writestr(info, data)
    os.replace(tmp, args.out)
    log(f'Escrito {args.out} ({len(db["files"])} ficheros)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
