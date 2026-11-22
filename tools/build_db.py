#!/usr/bin/env python3
#
# build_db.py - base de datos del Downloader de MiSTer para la Chameleon96
#
# Genera db.json.zip con db_id "distribution_mister": en la SD de la ch96,
# downloader.ini apunta [distribution_mister] a este fichero, así que el
# Downloader oficial (Scripts/update.sh) instala desde aquí en vez de desde
# MiSTer-devel/Distribution_MiSTer:
#
#   - cores: sources.ini, el último releases/<core>_AAAAMMDD_ch96.rbf de cada
#     repo (también vale el formato antiguo <core>_ch96_AAAAMMDD.rbf)
#   - arcades (secciones Arcade-*): el .rbf a _Arcade/cores/ sin "Arcade-" y
#     los releases/*.mra del mismo commit a _Arcade/
#   - ficheros de apoyo de los cores (ROMs de arranque...) y scripts de MiSTer
#     copiados de la base de datos oficial: campo "oficial" de cada core y
#     sección [oficial] de sources.ini
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
# Fecha del .rbf: Core_20261120_ch96.rbf (actual) o Core_ch96_20261117.rbf (antiguo)
DATE_RE = re.compile(r'_(\d{8})(_ch96)?\.rbf$', re.IGNORECASE)


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def git(*args, cwd=None):
    return subprocess.run(['git', *args], cwd=cwd, check=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout


def clone(repo, branch, work):
    """Clon sin blobs (solo se bajan los ficheros que se leen). Devuelve (dir, sha)."""
    dest = os.path.join(work, repo.replace('/', '__') + '__' + (branch or 'HEAD'))
    if not os.path.isdir(dest):
        cmd = ['clone', '-q', '--depth', '1', '--filter=blob:none', '--no-checkout']
        if branch:
            cmd += ['-b', branch]
        git(*cmd, f'https://github.com/{repo}.git', dest)
    return dest, git('rev-parse', 'HEAD', cwd=dest).decode().strip()


def copy_repo_files(repo, branch, lines, work, files, folders, extra_tags=()):
    """Ficheros sueltos de un repositorio, fijados a su último commit. Cada
    línea es "ruta/en/el/repo -> ruta/en/la/SD"."""
    dest_dir, sha = clone(repo, branch, work)
    for line in lines:
        if '->' not in line:
            raise RuntimeError(f'"{line}": falta "origen -> destino"')
        src, dst = (x.strip() for x in line.split('->', 1))
        data = git('show', f'HEAD:{src}', cwd=dest_dir)
        files[dst] = {'hash': hashlib.md5(data).hexdigest(), 'size': len(data),
                      'url': raw_url(repo, sha, src)}
        if dst.startswith('Scripts/'):
            add_tags(files[dst], ['scripts', tag_name(os.path.basename(dst).rsplit('.', 1)[0])])
        add_tags(files[dst], extra_tags)
        if '/' in dst:
            add_folders(dst.rsplit('/', 1)[0], folders,
                        ['scripts'] if dst.startswith('Scripts/') else None)
        log(f'  {dst:45s} <- {repo}@{sha[:7]} {src}')


def latest_release(repo, branch, pattern, work):
    """Clona sin blobs, elige el .rbf más reciente y devuelve (sha, ruta, bytes)."""
    dest, sha = clone(repo, branch, work)
    names = git('ls-tree', '--name-only', 'HEAD', 'releases/', cwd=dest).decode().split('\n')
    names = [os.path.basename(n) for n in names if n]
    pats = pattern.lower().split()
    cands = [n for n in names
             if any(fnmatch.fnmatch(n.lower(), p) for p in pats) and DATE_RE.search(n)]
    if not cands:
        raise RuntimeError(f'{repo}: no hay releases/{pattern}')
    # La fecha manda; a igualdad de fecha, el formato nuevo (_ch96 al final)
    best = max(cands, key=lambda n: (DATE_RE.search(n).group(1),
                                     bool(DATE_RE.search(n).group(2)), n))
    data = git('show', f'HEAD:releases/{best}', cwd=dest)
    return sha, f'releases/{best}', data, dest


def raw_url(repo, sha, path):
    return f'https://raw.githubusercontent.com/{repo}/{sha}/{urllib.parse.quote(path)}'


def default_pattern(section):
    """Los dos formatos de nombre de los .rbf de la ch96."""
    return f'{section}_*_ch96.rbf {section}_ch96_*.rbf'


def is_arcade(section):
    return section.lower().startswith('arcade-')


def install_name(section, filename):
    """Quita el _ch96 para que el menú muestre el core como en MiSTer:
         TS2068_20261120_ch96.rbf -> TS2068_20261120.rbf
         TS2068_ch96_20261117.rbf -> TS2068_20261117.rbf
    En los arcades quita también el "Arcade-", como la distribución oficial,
    porque el <rbf> de los .mra busca el core por ese nombre:
         Arcade-Galaga_20261120_ch96.rbf -> Galaga_20261120.rbf"""
    name = re.sub(r'_ch96(?=\.rbf$)', '', filename, flags=re.IGNORECASE)
    name = re.sub(r'_ch96(?=_\d{8}\.rbf$)', '', name, flags=re.IGNORECASE)
    if is_arcade(section):
        name = re.sub(r'^arcade-', '', name, flags=re.IGNORECASE)
    return name


# Etiquetas para los filtros del Downloader ("filter =" en downloader.ini). Se
# usan los mismos nombres que la distribución oficial, para que valgan los
# mismos filtros que en MiSTer.
CATEGORY_TAGS = {
    '_Computer': ['computercores'],
    '_Console': ['consolecores'],
    '_Other': ['othercores'],
    '_Utility': ['utility'],
    '_Arcade': ['arcadecores'],
    '_Arcade/cores': ['arcadecores'],
}


def tag_name(text):
    """ "Amstrad-PCW" -> "amstradpcw", como los nombres de la oficial."""
    return re.sub(r'[^a-z0-9]', '', text.lower())


def add_tags(entry, tags):
    for t in tags:
        if t and t not in entry.setdefault('tags', []):
            entry['tags'].append(t)


def add_folders(path, folders, tags=None):
    """Crea la carpeta y sus padres. Las carpetas de categoría (_Computer...)
    llevan sus etiquetas, como en la oficial."""
    parts = path.split('/')
    for i in range(1, len(parts) + 1):
        sub = '/'.join(parts[:i])
        entry = folders.setdefault(sub, {})
        add_tags(entry, CATEGORY_TAGS.get(sub, []))
        if sub == path and tags:
            add_tags(entry, tags)


def copy_mras(repo, sha, clone, patterns, folder, files, folders, name_tag=''):
    """Los .mra de releases/ del repositorio del core, a <folder>/ (los
    arcades: _Arcade/). Se toman del mismo commit que el .rbf."""
    names = git('ls-tree', '--name-only', 'HEAD', 'releases/', cwd=clone).decode().split('\n')
    names = sorted(os.path.basename(n) for n in names if n)
    mras = [n for n in names if any(fnmatch.fnmatchcase(n, p) for p in patterns)]
    if not mras:
        raise RuntimeError(f'{repo}: no hay releases/{" ".join(patterns)}')
    add_folders(folder, folders)
    for n in mras:
        data = git('show', f'HEAD:releases/{n}', cwd=clone)
        dest = f'{folder}/{n}'
        files[dest] = {'hash': hashlib.md5(data).hexdigest(), 'size': len(data),
                       'url': raw_url(repo, sha, f'releases/{n}')}
        # Las de la oficial (pantalla, controles...); si no está, las básicas
        add_tags(files[dest], official_tags(dest) or ['arcadecores', 'mra', name_tag])
        log(f'  {dest:45s} <- {repo}@{sha[:7]}')


def ini_list(value):
    """Una entrada por línea (las rutas pueden llevar espacios: "games/Amstrad PCW/*")."""
    return [l.strip() for l in (value or '').splitlines() if l.strip()]


_official = None


def official_db():
    global _official
    if _official is None:
        with urllib.request.urlopen(OFFICIAL_DB_URL, timeout=60) as r:
            z = zipfile.ZipFile(io.BytesIO(r.read()))
        _official = json.loads(z.read(z.namelist()[0]))
    return _official


def official_tags(path, kind='files'):
    """Etiquetas (por nombre) de una entrada de la base de datos oficial."""
    official = official_db()
    names = {v: k for k, v in official.get('tag_dictionary', {}).items()}
    desc = official.get(kind, {}).get(path) or {}
    return [names.get(t, t) if isinstance(t, int) else t for t in desc.get('tags', [])]


def copy_official(patterns, files, folders):
    """Copia entradas tal cual de la base de datos oficial de MiSTer: scripts
    que no dependen de la placa (wifi.sh, samba_on.sh...) y ficheros de apoyo
    de los cores (games/AO486/boot0.rom...). Admite comodines. La URL queda
    fijada al commit de Distribution_MiSTer que anuncia la base de datos
    oficial."""
    official = official_db()
    base = official.get('base_files_url', '')
    for pat in patterns:
        paths = sorted(p for p in official['files'] if fnmatch.fnmatchcase(p, pat))
        if not paths:
            raise RuntimeError(f'{pat} no está en la base de datos oficial')
        for path in paths:
            desc = official['files'][path]
            files[path] = {'hash': desc['hash'], 'size': desc['size'],
                           'url': desc.get('url') or base + urllib.parse.quote(path)}
            add_tags(files[path], official_tags(path))
            parts = path.split('/')[:-1]
            for i in range(1, len(parts) + 1):
                sub = '/'.join(parts[:i])
                add_folders(sub, folders, official_tags(sub, 'folders'))
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
                    copy_official(ini_list(s.get('files')), files, folders)
                except Exception as e:
                    errors.append(f'[{section}] {e}')
                continue
            repo = s.get('repo')
            if not repo:
                errors.append(f'[{section}] sin repo')
                continue
            if s.get('ficheros'):
                try:
                    copy_repo_files(repo, s.get('branch'), ini_list(s.get('ficheros')),
                                    work, files, folders, s.get('tags', '').split())
                except Exception as e:
                    errors.append(f'[{section}] {e}')
                if not s.get('pattern'):
                    continue  # solo ficheros, sin core
            pattern = s.get('pattern', default_pattern(section))
            try:
                sha, path, data, clone = latest_release(repo, s.get('branch'), pattern, work)
            except Exception as e:  # un core roto no tumba la base de datos
                errors.append(f'[{section}] {e}')
                continue

            target = s.get('target')
            name_tag = tag_name(section)  # "Arcade-Galaga" -> "arcadegalaga", como en la oficial
            if target:
                dest = target
                tags = ['cores', 'essential', name_tag] if target == 'menu.rbf' else [name_tag]
            else:
                default = '_Arcade/cores' if is_arcade(section) else '_Computer'
                folder = s.get('folder', default).strip('/')
                dest = f'{folder}/{install_name(section, os.path.basename(path))}'
                add_folders(folder, folders, ['cores'])
                tags = CATEGORY_TAGS.get(folder, []) + ['cores', name_tag]
                if is_arcade(section):
                    tags.append('arcaderbfsonly')

            entry = {
                'hash': hashlib.md5(data).hexdigest(),
                'size': len(data),
                'url': raw_url(repo, sha, path),
            }
            if dest == 'menu.rbf':
                entry.update({'path': 'system', 'reboot': True})
            add_tags(entry, tags + s.get('tags', '').split())
            files[dest] = entry
            log(f'  {dest:45s} <- {repo}@{sha[:7]} {path}')

            mra = s.get('mra', '*.mra' if is_arcade(section) else '')
            if mra.strip():
                try:
                    copy_mras(repo, sha, clone, mra.split(),
                              s.get('mra_folder', '_Arcade').strip('/'), files, folders,
                              name_tag)
                except Exception as e:
                    errors.append(f'[{section}] {e}')

            if s.get('oficial'):
                try:
                    copy_official(ini_list(s.get('oficial')), files, folders)
                except Exception as e:
                    errors.append(f'[{section}] {e}')

    system = load_json('system.json')
    if system and system.get('MiSTer'):
        m = system['MiSTer']
        files['MiSTer'] = {
            'hash': m['hash'], 'size': m['size'], 'url': m['url'],
            'path': 'system', 'reboot': True,
            'backup': '.MiSTer.old', 'tmp': 'MiSTer.new',
            'tags': ['essential', 'misterfirmware'],
        }
        log(f'  {"MiSTer":45s} <- {m["url"]}')

    # Etiquetas por número, con su diccionario (como la oficial: ocupa menos)
    names = sorted({t for e in list(files.values()) + list(folders.values())
                    for t in e.get('tags', [])})
    tag_dictionary = {t: i for i, t in enumerate(names)}
    for e in list(files.values()) + list(folders.values()):
        if 'tags' in e:
            e['tags'] = [tag_dictionary[t] for t in e['tags']]
    # Alias de la oficial: "computer" = "computercores", "arcade" = "arcadecores"...
    try:
        official = official_db().get('tag_dictionary', {})
        by_num = {}
        for name, num in official.items():
            by_num.setdefault(num, []).append(name)
        for name in names:
            for alias in by_num.get(official.get(name), []):
                tag_dictionary.setdefault(alias, tag_dictionary[name])
    except Exception as e:
        log(f'AVISO: sin alias de etiquetas de la oficial ({e})')
    tag_dictionary = dict(sorted(tag_dictionary.items()))

    db = {
        'v': 1,
        'db_id': DB_ID,
        'db_url': db_url,
        'timestamp': 0,
        'files': dict(sorted(files.items())),
        'folders': dict(sorted(folders.items())),
        'tag_dictionary': tag_dictionary,
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
