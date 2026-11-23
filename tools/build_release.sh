#!/bin/bash
#
# build_release.sh - paquete release_ch96_AAAAMMDD.7z para la Chameleon96
#
# Parte del release oficial de Linux de MiSTer (el que anuncia la base de
# datos de MiSTer-devel/Distribution_MiSTer) y cambia solo lo que depende de
# la placa:
#
#   files/MiSTer              teiram/Main_MiSTer_ch96 + ch96/Main_MiSTer_ch96-*.patch (gcc 10.2)
#   files/menu.rbf            teiram/Menu_MiSTer_ch96, último menu_*_ch96.rbf (o menu_ch96_*.rbf)
#   files/linux/zImage_dtb    kernel MiSTer (el mismo commit que el linux.img)
#                             + ch96/socfpga_cyclone5_chameleon96_mister.dts
#                             + ch96/kernel.fragment (red USB por cable)
#   files/linux/uboot.img     teiram/u-boot-socfpga (chameleon96) + ch96/*.patch
#   files/linux/linux.img     el oficial, ampliado 16 MB, con el firmware
#                             rtl_nic y /MiSTer.version = AAMMDD propio
#   files/downloader.ini      apunta el Downloader a esta distribución
#
# El mismo 7z sirve para crear la SD (tools/mk_mister_ch96_sd.sh) y para que
# el Downloader actualice Linux (campo "linux" de db.json.zip).
#
# Salida en $OUT (por defecto ./release):
#   release_ch96_AAAAMMDD.7z, MiSTer_ch96_AAAAMMDD, linux.json, system.json
#
# Variables:
#   LINUX_URL     release oficial (por defecto, el de la base de datos oficial)
#   KERNEL_REF    commit del kernel (por defecto, ch96/kernel_versions.txt)
#   VERSION       AAAAMMDD (por defecto, hoy en UTC)
#   REPO          usuario/repo donde se publican los assets
#   WORK          carpeta de trabajo (se reutiliza entre ejecuciones)
#   JOBS          trabajos de make
#
# Necesita: git curl 7z python3 debugfs (e2fsprogs) make gcc bc bison flex
#           libssl-dev lz4 u-boot-tools
#
# Autor: Shaeon (Carlos Palmero)

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/release}
WORK=${WORK:-$ROOT/work}
REPO=${REPO:-shaeon/Distribution_MiSTer_ch96}
VERSION=${VERSION:-$(date -u +%Y%m%d)}
JOBS=${JOBS:-$(nproc)}
SHORT=${VERSION:2:6}
TAG=release_ch96_$VERSION
ASSETS=https://github.com/$REPO/releases/download/$TAG

KERNEL_REPO=https://github.com/MiSTer-devel/Linux-Kernel_MiSTer.git
KERNEL_BRANCH=${KERNEL_BRANCH:-MiSTer-v6.18}
UBOOT_REPO=https://github.com/teiram/u-boot-socfpga.git
UBOOT_BRANCH=chameleon96
MAIN_REPO=https://github.com/teiram/Main_MiSTer_ch96.git
MENU_REPO=https://github.com/teiram/Menu_MiSTer_ch96.git
OFFICIAL_DB=https://raw.githubusercontent.com/MiSTer-devel/Distribution_MiSTer/main/db.json.zip
TC_NAME=gcc-arm-10.2-2020.11-x86_64-arm-none-linux-gnueabihf
TC_URL=https://developer.arm.com/-/media/Files/downloads/gnu-a/10.2-2020.11/binrel/$TC_NAME.tar.xz

DTS=socfpga_cyclone5_chameleon96_mister
DTS_DIR=arch/arm/boot/dts/intel/socfpga

say() { echo; echo "== $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

mkdir -p "$WORK" "$OUT"

# ---------------------------------------------------------------- toolchain
if [ ! -x "$WORK/$TC_NAME/bin/arm-none-linux-gnueabihf-gcc" ]; then
	say "Toolchain $TC_NAME"
	curl -fsSL "$TC_URL" | tar -xJ -C "$WORK"
fi
export PATH="$WORK/$TC_NAME/bin:$PATH"
export ARCH=arm CROSS_COMPILE=arm-none-linux-gnueabihf-

# ------------------------------------------------------- release oficial
if [ -z "${LINUX_URL:-}" ]; then
	LINUX_URL=$(curl -fsSL "$OFFICIAL_DB" | python3 -c '
import sys, io, json, zipfile
z = zipfile.ZipFile(io.BytesIO(sys.stdin.buffer.read()))
print(json.loads(z.read(z.namelist()[0]))["linux"]["url"])')
fi
say "Release oficial: $LINUX_URL"
REL_7Z="$WORK/$(basename "$LINUX_URL")"
[ -f "$REL_7Z" ] || curl -fsSL -o "$REL_7Z" "$LINUX_URL"
rm -rf "$WORK/rel"
7z x -y -bd -o"$WORK/rel" "$REL_7Z" files >/dev/null
FILES="$WORK/rel/files"
IMG="$FILES/linux/linux.img"
[ -f "$IMG" ] || die "el release no trae files/linux/linux.img"

OFFICIAL_VER=$(debugfs -R "cat /MiSTer.version" "$IMG" 2>/dev/null | tr -d '\r\n')
MODVER=$(debugfs -R "ls /lib/modules" "$IMG" 2>/dev/null | tr -s ' ' '\n' | grep -E '^[0-9]+\.[0-9]+' | head -1)
echo "linux.img oficial: versión $OFFICIAL_VER, módulos $MODVER"

# ------------------------------------------------------------------ kernel
KERNEL_REF=${KERNEL_REF:-$(awk -v v="$OFFICIAL_VER" '$1==v {print $2}' "$ROOT/ch96/kernel_versions.txt")}
[ -n "$KERNEL_REF" ] || die "no sé con qué commit del kernel se compiló el linux.img $OFFICIAL_VER.
Añade una línea en ch96/kernel_versions.txt o pasa KERNEL_REF=<commit de $KERNEL_BRANCH>."
say "Kernel MiSTer $KERNEL_REF"
KSRC="$WORK/kernel"
if [ ! -d "$KSRC/.git" ]; then
	git init -q "$KSRC"
	git -C "$KSRC" remote add origin "$KERNEL_REPO"
fi
if [ "$(git -C "$KSRC" rev-parse -q --verify HEAD 2>/dev/null)" != "$(git -C "$KSRC" rev-parse -q --verify "$KERNEL_REF^{commit}" 2>/dev/null || echo x)" ]; then
	git -C "$KSRC" fetch -q --depth 1 origin "$KERNEL_REF"
	git -C "$KSRC" checkout -q -f FETCH_HEAD
fi
cp "$ROOT/ch96/$DTS.dts" "$KSRC/$DTS_DIR/"
grep -q "$DTS.dtb" "$KSRC/$DTS_DIR/Makefile" || \
	sed -i "s|socfpga_cyclone5_de10_nano.dtb \\\\|socfpga_cyclone5_de10_nano.dtb \\\\\n\t$DTS.dtb \\\\|" "$KSRC/$DTS_DIR/Makefile"
make -C "$KSRC" -s MiSTer_defconfig
# Opciones propias de la Chameleon96 (red USB por cable)
"$KSRC/scripts/kconfig/merge_config.sh" -m -O "$KSRC" "$KSRC/.config" "$ROOT/ch96/kernel.fragment" >/dev/null
make -C "$KSRC" -s olddefconfig
for opt in $(grep -E '^CONFIG_[A-Z0-9_]+=y' "$ROOT/ch96/kernel.fragment" | cut -d= -f1); do
	grep -q "^$opt=y" "$KSRC/.config" || die "$opt no ha quedado activa en el kernel (ch96/kernel.fragment)"
done
make -C "$KSRC" -s -j"$JOBS" LOCALVERSION=-MiSTer zImage modules \
	intel/socfpga/$DTS.dtb intel/socfpga/socfpga_cyclone5_de10_nano.dtb

# Comprobaciones: el kernel tiene que ser el del linux.img
KREL=$(cat "$KSRC/include/config/kernel.release")
[ "$KREL" = "$MODVER" ] || die "el kernel es $KREL y los módulos del linux.img son $MODVER"
python3 - "$FILES/linux/zImage_dtb" "$KSRC/$DTS_DIR/socfpga_cyclone5_de10_nano.dtb" <<'EOF' || die "el DTB de la DE10 no coincide con el del release oficial (¿commit del kernel equivocado?)"
import struct, sys
z = open(sys.argv[1], 'rb').read()
end = struct.unpack('<I', z[0x2c:0x30])[0]
sys.exit(0 if z[end:] == open(sys.argv[2], 'rb').read() else 1)
EOF
echo "kernel $KREL y DTB de la DE10 iguales que los del release oficial"
cat "$KSRC/arch/arm/boot/zImage" "$KSRC/$DTS_DIR/$DTS.dtb" > "$FILES/linux/zImage_dtb"

# ------------------------------------------------------------------ U-Boot
say "U-Boot (teiram/u-boot-socfpga $UBOOT_BRANCH + parche MiSTer)"
rm -rf "$WORK/u-boot"
git clone -q --depth 1 -b "$UBOOT_BRANCH" "$UBOOT_REPO" "$WORK/u-boot"
git -C "$WORK/u-boot" apply "$ROOT/ch96/u-boot-socfpga-chameleon96-mister.patch"
UBOOT_SHA=$(git -C "$WORK/u-boot" rev-parse --short HEAD)
make -C "$WORK/u-boot" -s socfpga_chameleon96_defconfig
make -C "$WORK/u-boot" -s -j"$JOBS"
install -m 644 "$WORK/u-boot/u-boot-with-spl.sfp" "$FILES/linux/uboot.img"

# ------------------------------------------------------------ Main_MiSTer
say "Main_MiSTer_ch96"
rm -rf "$WORK/main"
git clone -q --depth 1 "$MAIN_REPO" "$WORK/main"
MAIN_SHA=$(git -C "$WORK/main" rev-parse --short HEAD)
for p in "$ROOT"/ch96/Main_MiSTer_ch96-*.patch; do
    [ -e "$p" ] || continue
    echo "aplicando $(basename "$p")"
    git -C "$WORK/main" apply "$p"
done
make -C "$WORK/main" -s MAKEFLAGS="-j$JOBS" >/dev/null
GLIBC=$(arm-none-linux-gnueabihf-objdump -T "$WORK/main/bin/MiSTer" | grep -o 'GLIBC_[0-9.]*' | sort -Vu | tail -1)
echo "MiSTer pide como máximo $GLIBC"
install -m 755 "$WORK/main/bin/MiSTer" "$FILES/MiSTer"

# ------------------------------------------------------------------- menu
say "Menu_MiSTer_ch96"
rm -rf "$WORK/menu"
git clone -q --depth 1 --filter=blob:none --no-checkout "$MENU_REPO" "$WORK/menu"
# menu_20261120_ch96.rbf (actual) o menu_ch96_20260808.rbf (antiguo): ordena por fecha
MENU=$(git -C "$WORK/menu" ls-tree --name-only HEAD releases/ \
    | sed -nE 's#^(releases/menu_(ch96_)?([0-9]{8})(_ch96)?\.rbf)$#\3\4 \1#p' \
    | grep -E '^[0-9]{8}(_ch96)? releases/menu_(ch96_[0-9]{8}|[0-9]{8}_ch96)\.rbf$' \
    | sort | tail -1 | cut -d' ' -f2)
[ -n "$MENU" ] || die "no hay releases/menu_*_ch96.rbf"
git -C "$WORK/menu" show "HEAD:$MENU" > "$FILES/menu.rbf"
echo "$MENU"

# --------------------------------------------- linux.img y extras de la SD
# El linux.img oficial viene lleno: se amplía 16 MB para lo que se añade.
say "linux.img: +16 MB"
truncate -s +16M "$IMG"
e2fsck -fy "$IMG" >/dev/null 2>&1 || true
e2fsck -fn "$IMG" >/dev/null || die "linux.img con errores antes de ampliarlo"
resize2fs "$IMG" >/dev/null 2>&1 || die "resize2fs"

# Escribe un fichero en el linux.img como root:root
img_write() { # origen destino modo
	debugfs -w -R "rm $2" "$IMG" >/dev/null 2>&1 || true
	debugfs -w -R "write $1 $2" "$IMG" >/dev/null 2>&1
	debugfs -w -R "sif $2 uid 0" "$IMG" >/dev/null 2>&1
	debugfs -w -R "sif $2 gid 0" "$IMG" >/dev/null 2>&1
	debugfs -w -R "sif $2 mode 0100$3" "$IMG" >/dev/null 2>&1
	[ "$(debugfs -R "cat $2" "$IMG" 2>/dev/null | md5sum)" = "$(md5sum < "$1")" ] || \
		die "no se pudo escribir $2 en el linux.img"
}

say "linux.img: firmware rtl_nic (RTL8153/RTL8156)"
FW_URL=https://gitlab.com/kernel-firmware/linux-firmware/-/raw/main
mkdir -p "$WORK/rtl_nic"
debugfs -w -R "mkdir /usr/lib/firmware/rtl_nic" "$IMG" >/dev/null 2>&1 || true
for f in uid gid; do debugfs -w -R "sif /usr/lib/firmware/rtl_nic $f 0" "$IMG" >/dev/null 2>&1; done
for fw in $(grep -o '"rtl_nic/[^"]*\.fw"' "$KSRC/drivers/net/usb/r8152.c" | tr -d '"' | sort -u); do
	[ -s "$WORK/$fw" ] || curl -fsSL -o "$WORK/$fw" "$FW_URL/$fw" || die "no se pudo descargar $fw"
	img_write "$WORK/$fw" "/usr/lib/firmware/$fw" 644
	echo "  $fw"
done

say "linux.img: MiSTer.version $OFFICIAL_VER -> $SHORT"
printf '%s' "$SHORT" > "$WORK/MiSTer.version"
img_write "$WORK/MiSTer.version" /MiSTer.version 644
[ "$(debugfs -R "cat /MiSTer.version" "$IMG" 2>/dev/null)" = "$SHORT" ] || die "no se pudo escribir /MiSTer.version"
e2fsck -fn "$IMG" >/dev/null || die "linux.img con errores tras el cambio"

say "Scripts de MiSTer ([oficial] de sources.ini)"
python3 - "$ROOT/sources.ini" "$OFFICIAL_DB" "$FILES" <<'EOF' || die "no se pudieron copiar los scripts de MiSTer"
import configparser, hashlib, io, json, os, sys, urllib.parse, urllib.request, zipfile
ini, db_url, files = sys.argv[1:]
cfg = configparser.ConfigParser(inline_comment_prefixes=(';', '#'))
cfg.read(ini)
paths = cfg['oficial'].get('files', '').split() if cfg.has_section('oficial') else []
z = zipfile.ZipFile(io.BytesIO(urllib.request.urlopen(db_url, timeout=60).read()))
db = json.loads(z.read(z.namelist()[0]))
for p in paths:
    d = db['files'][p]
    url = d.get('url') or db['base_files_url'] + urllib.parse.quote(p)
    data = urllib.request.urlopen(url, timeout=60).read()
    if hashlib.md5(data).hexdigest() != d['hash']:
        sys.exit(f'{p}: el MD5 no coincide')
    dest = os.path.join(files, p)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    open(dest, 'wb').write(data)
    print('  ' + p)
EOF

say "Scripts propios de la ch96 (ch96/Scripts)"
for s in "$ROOT"/ch96/Scripts/*.sh; do
	[ -f "$s" ] || continue
	install -D -m 755 "$s" "$FILES/Scripts/$(basename "$s")"
	echo "  Scripts/$(basename "$s")"
done

cat > "$FILES/downloader.ini" <<EOF
[MiSTer]
update_linux = true

; Chameleon96: todo (cores, menu.rbf, MiSTer y Linux) viene de
; https://github.com/$REPO
[distribution_mister]
db_url = https://raw.githubusercontent.com/$REPO/main/db.json.zip
EOF

cat > "$FILES/linux/ch96_build.txt" <<EOF
release_ch96_$VERSION
linux.img oficial $OFFICIAL_VER ($(basename "$LINUX_URL")), módulos $MODVER
kernel  MiSTer-devel/Linux-Kernel_MiSTer $KERNEL_REF + ch96/$DTS.dts + ch96/kernel.fragment
u-boot  teiram/u-boot-socfpga $UBOOT_BRANCH@$UBOOT_SHA + ch96/u-boot-socfpga-chameleon96-mister.patch
MiSTer  teiram/Main_MiSTer_ch96@$MAIN_SHA + ch96/Main_MiSTer_ch96-*.patch
menu    teiram/Menu_MiSTer_ch96 $MENU
EOF

# ------------------------------------------------------------- empaquetado
say "Empaquetando $TAG.7z"
PKG="$OUT/$TAG.7z"
rm -f "$PKG"
(cd "$WORK/rel" && 7z a -t7z -mx=9 -bd "$PKG" files >/dev/null)
install -m 755 "$FILES/MiSTer" "$OUT/MiSTer_ch96_$VERSION"

python3 - "$PKG" "$OUT/MiSTer_ch96_$VERSION" "$ASSETS" "$SHORT" "$OUT" <<'EOF'
import hashlib, json, os, sys
pkg, main, assets, short, out = sys.argv[1:]
def desc(p):
    b = open(p, 'rb').read()
    return {'hash': hashlib.md5(b).hexdigest(), 'size': len(b),
            'url': f'{assets}/{os.path.basename(p)}'}
linux = desc(pkg); linux['version'] = short
json.dump(linux, open(os.path.join(out, 'linux.json'), 'w'), indent=1)
json.dump({'MiSTer': desc(main)}, open(os.path.join(out, 'system.json'), 'w'), indent=1)
EOF

cat "$FILES/linux/ch96_build.txt"
ls -la "$OUT"
