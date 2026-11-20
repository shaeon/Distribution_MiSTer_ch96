#!/bin/bash
#
# test_mrfusion_qemu.sh - prueba el instalador de la Chameleon96 en qemu
#
# Arranca el initramfs del instalador (work/mrfusion/initramfs, el que deja
# tools/build_mrfusion.sh) con un kernel del mismo árbol compilado para la
# placa vexpress-a9 de qemu (Cortex-A9, como la Chameleon96), usando como SD
# una copia de la imagen del instalador ampliada al tamaño indicado. El /init
# es el mismo: reparticiona, formatea, descomprime y graba la A2 de verdad.
#
# Después comprueba la tarjeta resultante:
#   - exFAT en toda la tarjeta menos 4 MB y A2 al final
#   - todos los ficheros del paquete, idénticos
#   - la A2 contiene linux/uboot.img
#
# Uso: tools/test_mrfusion_qemu.sh release/mrfusion_ch96_AAAAMMDD.img [2G]
#
# Necesita: qemu-system-arm, exfat-fuse (o exFAT en el kernel), root para losetup
#
# Autor: Shaeon (Carlos Palmero)

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
IMG=${1:?uso: $0 mrfusion_ch96_AAAAMMDD.img [tamaño]}
SIZE=${2:-2G}
WORK=${WORK:-$ROOT/work}
KSRC=${KSRC:-$WORK/kernel}
KT="$WORK/ktest"
R="$WORK/mrfusion/initramfs"
TC_NAME=gcc-arm-10.2-2020.11-x86_64-arm-none-linux-gnueabihf
[ -d "$WORK/$TC_NAME/bin" ] && export PATH="$WORK/$TC_NAME/bin:$PATH"
export ARCH=arm CROSS_COMPILE=arm-none-linux-gnueabihf-

[ -x "$R/init" ] || { echo "Falta $R: ejecuta antes tools/build_mrfusion.sh"; exit 1; }

echo "== Kernel de prueba (vexpress-a9) con el initramfs del instalador"
COMMIT=$(git -C "$KSRC" rev-parse HEAD)
if [ "$(git -C "$KT" rev-parse HEAD 2>/dev/null)" != "$COMMIT" ]; then
	rm -rf "$KT"; git -C "$KSRC" worktree prune
	git -C "$KSRC" worktree add -q --detach "$KT" "$COMMIT"
fi
make -C "$KT" -s vexpress_defconfig
"$KT/scripts/config" --file "$KT/.config" \
	--enable BLK_DEV_INITRD --set-str INITRAMFS_SOURCE "$R" \
	--set-val INITRAMFS_ROOT_UID 0 --set-val INITRAMFS_ROOT_GID 0 \
	--enable DEVTMPFS --enable MMC_ARMMMCI --enable VFAT_FS --enable EXFAT_FS \
	--enable NLS_CODEPAGE_437 --enable NLS_ISO8859_1 --enable MSDOS_PARTITION \
	--enable TMPFS --enable MAGIC_SYSRQ --enable BLK_DEV_LOOP --disable MODULES
make -C "$KT" -s olddefconfig
make -C "$KT" -s -j"$(nproc)" zImage arm/vexpress-v2p-ca9.dtb

echo "== Tarjeta de $SIZE"
CARD="$WORK/card_test.img"
cp "$IMG" "$CARD"
truncate -s "$SIZE" "$CARD"

echo "== Instalando en qemu"
timeout 900 qemu-system-arm -M vexpress-a9 -m 512 -nographic -no-reboot \
	-kernel "$KT/arch/arm/boot/zImage" -dtb "$KT/arch/arm/boot/dts/arm/vexpress-v2p-ca9.dtb" \
	-sd "$CARD" -append "console=ttyAMA0 loglevel=3" | tee "$WORK/qemu.log" | grep "mrfusion_ch96:"
grep -q "instalación terminada" "$WORK/qemu.log" || { echo "FALLO: el instalador no terminó"; exit 1; }

echo "== Comprobando la tarjeta"
sfdisk -l "$CARD" | tail -3
read -r S1 N1 < <(sfdisk -d "$CARD" | awk -F'[=,]' '/start=/ {print $2+0, $4+0; exit}')
A2=$(sfdisk -d "$CARD" | awk -F'[=,]' '/type=a2/ {print $2+0}')
TOTAL=$(( $(stat -c %s "$CARD") / 512 ))
[ $(( A2 + 8192 )) = "$TOTAL" ] && [ $(( S1 + N1 )) = "$A2" ] || { echo "FALLO: particiones"; exit 1; }

T=$(mktemp -d)
trap 'mountpoint -q "$T/sd" && umount "$T/sd"; [ -n "${L:-}" ] && losetup -d "$L"; rm -rf "$T"' EXIT
mkdir -p "$T/sd" "$T/rel"
VERSION=$(basename "$IMG" .img); VERSION=${VERSION#mrfusion_ch96_}
7z x -bd -o"$T/rel" "$(dirname "$IMG")/release_ch96_$VERSION.7z" files >/dev/null
L=$(losetup -f --show -r -o $(( S1 * 512 )) --sizelimit $(( N1 * 512 )) "$CARD")
mount -t exfat -o ro "$L" "$T/sd" 2>/dev/null || mount.exfat-fuse -o ro "$L" "$T/sd"
if diff -rq "$T/rel/files" "$T/sd" | grep -v "^Only in $T/sd"; then
	echo "FALLO: ficheros distintos"; exit 1
fi
UB="$T/sd/linux/uboot.img"
cmp -n "$(stat -c %s "$UB")" "$UB" <(dd if="$CARD" bs=512 skip="$A2" count=8192 status=none) || \
	{ echo "FALLO: A2"; exit 1; }
echo "OK: tarjeta de $SIZE instalada correctamente"
