#!/bin/bash
#
# build_mrfusion.sh - instalador de MiSTer para la Chameleon96 (estilo Mr. Fusion)
#
# Genera mrfusion_ch96_AAAAMMDD.img, una imagen pequeña que se graba con
# Etcher / Win32DiskImager / dd en una tarjeta de cualquier tamaño. En el
# primer arranque se amplía a la tarjeta entera e instala MiSTer
# (ch96/mrfusion/init).
#
#   p1  FAT32 "MRFUSION"
#         menu.rbf                  U-Boot lo carga en la FPGA, como siempre
#         linux/zImage_dtb          kernel del instalador (initramfs dentro)
#         mrfusion/payload.tar.xz   ficheros de la SD (del release_ch96)
#         extra/                    lo que se copia encima al terminar
#         LEEME.txt
#   p2  A2: linux/uboot.img del release (el mismo U-Boot de la SD final)
#
# U-Boot arranca igual que en la SD de MiSTer; el kernel del instalador lleva
# el initramfs dentro y su DTB da a Linux los 512 MB enteros.
#
# Uso (como root; si no, el script se relanza solo con sudo):
#   tools/build_mrfusion.sh release/release_ch96_AAAAMMDD.7z
#
# Variables:
#   KSRC   árbol del kernel MiSTer en el commit del release (por defecto
#          work/kernel, el que deja tools/build_release.sh)
#   OUT    carpeta de salida (por defecto ./release)
#   WORK   carpeta de trabajo (por defecto ./work)
#
# Necesita: 7z xz cpio mtools sfdisk fdtput (device-tree-compiler), la
#           toolchain de MiSTer en el PATH (o en work/) y lo de compilar el kernel
#
# Autor: Shaeon (Carlos Palmero)

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
RELEASE=${1:?uso: $0 release_ch96_AAAAMMDD.7z}
OUT=${OUT:-$ROOT/release}
WORK=${WORK:-$ROOT/work}
KSRC=${KSRC:-$WORK/kernel}
JOBS=${JOBS:-$(nproc)}
TC_NAME=gcc-arm-10.2-2020.11-x86_64-arm-none-linux-gnueabihf
DTS=socfpga_cyclone5_chameleon96_mister
# El linux.img oficial tiene /usr con permisos 770 (root): para sacar busybox
# y las librerías hay que ser root. Si no lo somos (runner de GitHub), el
# script se relanza con sudo y al terminar devuelve lo generado al usuario.
if [ "$(id -u)" != 0 ]; then
	exec sudo -E env "PATH=$PATH:/usr/local/sbin:/usr/sbin:/sbin" HOME="$HOME" bash "$0" "$@"
fi
SUDO=

say() { echo; echo "== $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

[ -d "$WORK/$TC_NAME/bin" ] && export PATH="$WORK/$TC_NAME/bin:$PATH"
export ARCH=arm CROSS_COMPILE=arm-none-linux-gnueabihf-
command -v ${CROSS_COMPILE}gcc >/dev/null || die "falta la toolchain $TC_NAME"
[ -f "$KSRC/Makefile" ] || die "no está el kernel en $KSRC (ejecuta antes tools/build_release.sh)"

NAME=$(basename "$RELEASE" .7z)
VERSION=${NAME#release_ch96_}
IMG_OUT="$OUT/mrfusion_ch96_$VERSION.img"
M="$WORK/mrfusion"
LI="$M/linux.img.mnt"

cleanup() {
	set +e
	mountpoint -q "$LI" && umount "$LI"
	if [ -n "${SUDO_UID:-}" ]; then
		chown -R "$SUDO_UID:$SUDO_GID" "$OUT" "$WORK"
	fi
}
trap cleanup EXIT

rm -rf "$M"
mkdir -p "$M" "$OUT"

# ---------------------------------------------------------------- release
say "Release $NAME"
7z x -y -bd -o"$M/rel" "$RELEASE" files >/dev/null
FILES="$M/rel/files"
[ -f "$FILES/linux/ch96_build.txt" ] || die "no es un paquete release_ch96"
[ -f "$ROOT/ch96/MiSTer.ini" ] && install -m 644 "$ROOT/ch96/MiSTer.ini" "$FILES/MiSTer.ini"
mkdir -p "$FILES/_Computer" "$FILES/_Console" "$FILES/_Other" "$FILES/_Arcade"

# --------------------------------------------------------------- initramfs
say "initramfs con los binarios del linux.img oficial"
R="$M/initramfs"
mkdir -p "$R"/{bin,sbin,lib,usr/bin,usr/sbin,proc,sys,dev,tmp,src,dst,extra} "$LI"
mount -o loop,ro "$FILES/linux/linux.img" "$LI"

# Copia un fichero del linux.img siguiendo los enlaces (la ruta puede
# pasar por /lib -> usr/lib)
img_resolve() { # ruta absoluta dentro de la imagen -> ruta real en el host
	local p=$1 i=0
	while [ $i -lt 40 ]; do
		local acc="" rest=${p#/} part
		local changed=0
		IFS=/ read -ra parts <<< "$rest"
		for part in "${parts[@]}"; do
			acc="$acc/$part"
			if [ -L "$LI$acc" ]; then
				local t; t=$(readlink "$LI$acc")
				case $t in /*) ;; *) t="$(dirname "$acc")/$t" ;; esac
				local tail=${p#"$acc"}
				p=$(realpath -m "$t")$tail
				changed=1
				break
			fi
		done
		[ $changed = 0 ] && { echo "$LI$p"; return 0; }
		i=$((i + 1))
	done
	return 1
}

declare -A DONE
add_elf() { # ruta en la imagen
	local src; src=$(img_resolve "$1")
	[ -f "$src" ] || die "no está $1 en el linux.img"
	local dst="$R/lib/$(basename "$1")"
	case $1 in */bin/*|*/sbin/*) dst="$R$1" ;; esac
	install -D -m 755 "$src" "$dst"
	local lib
	for lib in $(readelf -d "$src" | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p'); do
		[ -n "${DONE[$lib]:-}" ] && continue
		DONE[$lib]=1
		add_elf "/usr/lib/$lib"
	done
}
add_elf /bin/busybox
add_elf /sbin/sfdisk
add_elf /sbin/mkfs.exfat
INTERP=$(readelf -l "$(img_resolve /bin/busybox)" | sed -n 's/.*interpreter: \(.*\)\]/\1/p')
install -D -m 755 "$(img_resolve "$INTERP")" "$R$INTERP"
ln -sf lib "$R/usr/lib"

for a in sh ash awk cat cp dd echo ls mkdir mount umount reboot rm sleep usleep \
         sync tar xz wc mountpoint; do
	ln -sf busybox "$R/bin/$a"
done
install -m 755 "$ROOT/ch96/mrfusion/init" "$R/init"
umount "$LI"

# Comprobación: el init con los binarios ARM (qemu-arm si está)
QEMU_ARM=$(command -v qemu-arm-static || command -v qemu-arm || true)
if [ -n "$QEMU_ARM" ]; then
	for b in "/bin/busybox --help" "/sbin/sfdisk --version" "/sbin/mkfs.exfat -V"; do
		set -- $b
		o=$("$QEMU_ARM" -L "$R" "$R$1" "$2" 2>&1 || true)
		echo "$o" | grep -qiE "busybox|util-linux|exfatprogs" || die "$1 no arranca en el initramfs: $o"
	done
	"$QEMU_ARM" -L "$R" "$R/bin/busybox" sh -n "$R/init" || die "el init tiene errores de sintaxis"
	echo "binarios del initramfs comprobados con $(basename "$QEMU_ARM")"
else
	echo "AVISO: sin qemu-arm, no se comprueban los binarios del initramfs"
fi
du -sh "$R"

# ---------------------------------------------------- kernel del instalador
say "Kernel del instalador"
# Árbol aparte (worktree del mismo commit): el de build_release.sh ya está
# configurado para el kernel normal y "make O=" exige un árbol limpio.
KO="$WORK/kinst"
COMMIT=$(git -C "$KSRC" rev-parse HEAD)
if [ "$(git -C "$KO" rev-parse HEAD 2>/dev/null)" != "$COMMIT" ]; then
	rm -rf "$KO"; git -C "$KSRC" worktree prune
	git -C "$KSRC" worktree add -q --detach "$KO" "$COMMIT"
fi
cp "$ROOT/ch96/$DTS.dts" "$KO/arch/arm/boot/dts/intel/socfpga/"
grep -q "$DTS.dtb" "$KO/arch/arm/boot/dts/intel/socfpga/Makefile" || \
	sed -i "s|socfpga_cyclone5_de10_nano.dtb \\\\|socfpga_cyclone5_de10_nano.dtb \\\\\n\t$DTS.dtb \\\\|" "$KO/arch/arm/boot/dts/intel/socfpga/Makefile"
make -C "$KO" -s MiSTer_defconfig
"$KO/scripts/config" --file "$KO/.config" \
	--enable BLK_DEV_INITRD --set-str INITRAMFS_SOURCE "$R" \
	--set-val INITRAMFS_ROOT_UID 0 --set-val INITRAMFS_ROOT_GID 0 \
	--enable RD_XZ --enable INITRAMFS_COMPRESSION_XZ
make -C "$KO" -s olddefconfig
grep -q '^CONFIG_BLK_DEV_INITRD=y' "$KO/.config" || die "no se pudo activar el initramfs en el kernel"
make -C "$KO" -s -j"$JOBS" LOCALVERSION=-MiSTer-installer zImage intel/socfpga/$DTS.dtb

# DTB del instalador: el de la ch96 sin la reserva de MiSTer (Linux ve 512 MB)
cp "$KO/arch/arm/boot/dts/intel/socfpga/$DTS.dtb" "$M/installer.dtb"
fdtput -r "$M/installer.dtb" /reserved-memory
fdtput -r "$M/installer.dtb" /MiSTer_fb
mkdir -p "$M/fat/linux" "$M/fat/mrfusion" "$M/fat/extra"
cat "$KO/arch/arm/boot/zImage" "$M/installer.dtb" > "$M/fat/linux/zImage_dtb"

# ------------------------------------------------------------- partición 1
say "Paquete (tar.xz)"
install -m 644 "$FILES/menu.rbf" "$M/fat/menu.rbf"
install -m 644 "$ROOT/ch96/mrfusion/LEEME.txt" "$M/fat/LEEME.txt"
tar -C "$FILES" --owner=0 --group=0 -cf - . | xz -T0 -6 > "$M/fat/mrfusion/payload.tar.xz"
cp "$FILES/linux/ch96_build.txt" "$M/fat/mrfusion/"
ls -la "$M/fat/mrfusion"

# ------------------------------------------------------------------ imagen
say "Imagen $IMG_OUT"
FAT_MB=$(( $(du -sm "$M/fat" | cut -f1) + 24 ))
P1=$(( FAT_MB * 2048 ))
TOTAL=$(( 2048 + P1 + 8192 ))
rm -f "$IMG_OUT"
truncate -s $(( TOTAL * 512 )) "$IMG_OUT"
sfdisk -q "$IMG_OUT" <<EOF
label: dos
start=2048, size=$P1, type=c, bootable
start=$(( 2048 + P1 )), size=8192, type=a2
EOF
mformat -i "$IMG_OUT@@1M" -T $P1 -F -v MRFUSION ::
mcopy -i "$IMG_OUT@@1M" -s "$M/fat"/* ::
mdir -i "$IMG_OUT@@1M" -/ :: | grep -v "^$" | tail -12
dd if="$FILES/linux/uboot.img" of="$IMG_OUT" bs=512 seek=$(( 2048 + P1 )) conv=notrunc status=none

sfdisk -l "$IMG_OUT"
(cd "$OUT" && rm -f "$(basename "$IMG_OUT").zip" && zip -q -9 "$(basename "$IMG_OUT").zip" "$(basename "$IMG_OUT")")
ls -la "$IMG_OUT" "$IMG_OUT.zip"
