#!/bin/bash
#
# mk_mister_ch96_sd.sh - SD de MiSTer para la Chameleon96
#
# Monta una SD con la misma estructura que la de MiSTer en la DE10-Nano
# (la que deja Mr. Fusion / SD Installer):
#
#   p1  exFAT "MiSTer_Data"  (toda la tarjeta menos 4 MB)
#         MiSTer, menu.rbf, MiSTer.ini, downloader.ini, Scripts/update.sh,
#         linux/linux.img, linux/zImage_dtb, linux/uboot.img...
#   p2  tipo A2 (4 MB al final)  SPL + U-Boot (lo lee la Boot ROM)
#
# Uso (Linux o WSL2, como root):
#   sudo ./mk_mister_ch96_sd.sh -r release_ch96_AAAAMMDD.7z sdcard.img [tamaño]
#   sudo ./mk_mister_ch96_sd.sh -r release_ch96_AAAAMMDD.7z /dev/sdX
#
#   -r  paquete release_ch96 (assets de las releases de Distribution_MiSTer_ch96,
#       o tools/build_release.sh)
#   -c  carpeta de cores _ch96 que se copia tal cual a la raíz de la SD
#       (no hace falta: Scripts/update.sh ya los descarga)
#   tamaño: solo para imágenes, por defecto 2G (se graba con dd, Etcher o
#       Win32DiskImager; el exFAT ocupa todo el tamaño de la imagen)
#
# Autor: Shaeon (Carlos Palmero)

set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE=
CORES=
TARGET=
SIZE=2G

usage() {
	sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
	exit 1
}

while getopts "r:c:h" opt; do
	case $opt in
		r) RELEASE=$OPTARG ;;
		c) CORES=$(cd "$OPTARG" && pwd) ;;
		*) usage ;;
	esac
done
shift $((OPTIND - 1))
TARGET=$1
[ -n "$2" ] && SIZE=$2
[ -n "$TARGET" ] && [ -n "$RELEASE" ] || usage

[ "$(id -u)" = 0 ] || { echo "Hay que ejecutarlo como root (sudo)."; exit 1; }

for t in sfdisk mkfs.exfat losetup dd 7z; do
	command -v $t >/dev/null || { echo "Falta $t (paquetes: fdisk exfatprogs p7zip-full)"; exit 1; }
done

WORK=$(mktemp -d)
MNT=$WORK/mnt
LOOP=
cleanup() {
	set +e
	mountpoint -q "$MNT" && umount "$MNT"
	[ -n "$LOOP" ] && losetup -d "$LOOP"
	rm -rf "$WORK"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
echo "== Extrayendo $RELEASE"
7z x -y -bd -o"$WORK/rel" "$RELEASE" files >/dev/null
FILES="$WORK/rel/files"
if [ ! -f "$FILES/linux/ch96_build.txt" ] || [ ! -f "$FILES/downloader.ini" ]; then
	echo "No es un paquete release_ch96: el release oficial de MiSTer no arranca en la Chameleon96."
	exit 1
fi
cat "$FILES/linux/ch96_build.txt"

[ -f "$ROOT/ch96/MiSTer.ini" ] && install -m 644 "$ROOT/ch96/MiSTer.ini" "$FILES/MiSTer.ini"
mkdir -p "$FILES/_Computer" "$FILES/_Console" "$FILES/_Other" "$FILES/_Arcade"
[ -n "$CORES" ] && cp -r "$CORES"/. "$FILES"/

# ---------------------------------------------------------------------------
if [ -b "$TARGET" ]; then
	echo "== Vas a BORRAR $TARGET:"
	lsblk "$TARGET" || true
	read -r -p "Escribe SI para seguir: " ok
	[ "$ok" = "SI" ] || exit 1
	for p in "$TARGET"?*; do umount "$p" 2>/dev/null || true; done
	DEV=$TARGET
	SECTORS=$(blockdev --getsz "$DEV")
else
	echo "== Creando la imagen $TARGET ($SIZE)"
	rm -f "$TARGET"
	truncate -s "$SIZE" "$TARGET"
	DEV=$TARGET
	SECTORS=$(( $(stat -c %s "$TARGET") / 512 ))
fi

# Mismo particionado que Mr. Fusion: exFAT en casi toda la tarjeta y la A2
# en los últimos 4 MB (8192 sectores).
DATA_SECTORS=$(( SECTORS - 2048 - 8192 ))
echo "== Particionando"
sfdisk --force -q "$DEV" <<EOF
label: dos
start=2048, size=$DATA_SECTORS, type=7
start=$(( 2048 + DATA_SECTORS )), size=8192, type=a2
EOF
sync

P1_OFF=$(( 2048 * 512 ))
P1_LEN=$(( DATA_SECTORS * 512 ))
P2_OFF=$(( (2048 + DATA_SECTORS) * 512 ))

echo "== Formateando exFAT (MiSTer_Data)"
LOOP=$(losetup -f --show -o $P1_OFF --sizelimit $P1_LEN "$DEV")
mkfs.exfat -L MiSTer_Data "$LOOP" >/dev/null

echo "== Copiando ficheros"
mkdir -p "$MNT"
mount -t exfat "$LOOP" "$MNT" 2>/dev/null || mount.exfat-fuse "$LOOP" "$MNT"
cp -r "$FILES"/. "$MNT"/
sync
umount "$MNT"
losetup -d "$LOOP"; LOOP=

echo "== Grabando SPL + U-Boot en la partición A2"
dd if="$FILES/linux/uboot.img" of="$DEV" bs=512 seek=$(( P2_OFF / 512 )) conv=notrunc,fsync status=none
dd if=/dev/zero of="$DEV" bs=512 seek=1 count=1 conv=notrunc,fsync status=none
sync

echo
sfdisk -l "$DEV"
echo
echo "Hecho: $TARGET"
