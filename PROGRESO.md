# SD de MiSTer para la Chameleon96 — progreso

Objetivo: misma SD que MiSTer en la DE10-Nano (exFAT `MiSTer_Data` + partición A2),
usando el `linux.img` oficial sin tocar y solo cambiando las piezas propias de la placa.

## Piezas

| Pieza | Origen | Estado |
|---|---|---|
| `linux/linux.img` | release oficial MiSTer 20260912 (sin cambios) | ok |
| `MiSTer` | teiram/Main_MiSTer_ch96 @ d9799de, gcc 10.2-2020.11 (glibc ≤ 2.29, el linux.img trae 2.31) | compilado |
| `menu.rbf` | teiram/Menu_MiSTer_ch96 `releases/menu_ch96_20260808.rbf` | ok |
| `linux/uboot.img` | teiram/u-boot-socfpga rama chameleon96 @ 1d6a164 + `patches/u-boot-socfpga-chameleon96-mister.patch` | compilado |
| `linux/zImage_dtb` | MiSTer-devel/Linux-Kernel_MiSTer @ 912aa56 (6.18.38, el del release 20260912, para que encajen los módulos del linux.img) + `socfpga_cyclone5_chameleon96_mister.dts` | compilado (vermagic `6.18.38-MiSTer SMP mod_unload ARMv7 p2v8`, igual que los 94 módulos del linux.img) |
| `MiSTer.ini` | MiSTer_example.ini con `video_mode=0` | ok |
| `mk_mister_ch96_sd.sh` | monta la SD o la imagen | probado: genera la imagen; U-Boot sandbox lee el exFAT, importa u-boot.txt y encuentra el DTB |

## Cambios en U-Boot (patch)

- Entorno de arranque de MiSTer (`u-boot_MiSTer`, DE10): `menu.rbf` → FPGA, `linux/u-boot.txt`,
  `linux/zImage_dtb` con el DTB pegado detrás, `root=/dev/mmcblk0p1 loop=linux/linux.img`.
- `mt` (comando privado del U-Boot de MiSTer) → `itest.l`.
- Sin `mem=511M memmap=...`: el DTB reserva 0x10000000-0x1FFFFFFF (no-map).
- `CONFIG_FS_EXFAT=y` (+ arreglo de `fs/exfat/time.c`: división de 64 bits con signo
  sin `__aeabi_ldivmod` en arm32).
- `CONFIG_ENV_IS_NOWHERE`: siempre el entorno por defecto, la personalización va en `u-boot.txt`.
- `board_get_usable_ram_top()` = 0x10000000: con 512 MB, U-Boot se recolocaba encima de
  0x1FFFF000 y pisaba la página donde Main deja el core para el reinicio en caliente.

## DTS (kernel MiSTer)

Base de teiram (`socfpga_cyclone5_chameleon96.dts`) + nodos MiSTer de la DE10:
`MiSTer_fb` en 0x1D000000 con IRQ 40 (el sys de ch96 tiene `f2h_irq`), uart1 sin DMA,
usb1 host con `disable-over-current`, puentes FPGA, `flags-sram` en OCRAM, i2c2 a 100 kHz
(TDA19988, lo programa Main). Sin gmac (no hay PHY), sin spi-audio (ch96 compila con
`MISTER_DISABLE_ALSA`), sin gpio-leds (los LED van por LoanIO desde la FPGA).

## Pendiente

- [ ] Probar en la placa: consola serie (ttyS0 115200) durante el arranque.
- [x] Actualizador: repo Distribution_MiSTer_ch96 con db.json.zip propio (db_id distribution_mister)
      y downloader.ini en la SD. Probado con el Downloader real en modo PC: instala cores, menu.rbf y
      MiSTer, y borra la versión vieja de un core al salir una nueva.
- [ ] Subir el repo a github.com/shaeon/Distribution_MiSTer_ch96 y lanzar el workflow Release.
- [ ] Probar en la placa la actualización de Linux (en modo PC el Downloader no la hace).
- [ ] WiFi integrada de la placa (no está en el DTS); de momento, adaptador WiFi USB.
- [ ] Sonido de Linux (spi-audio) desactivado en el sys de ch96.

## Comprobado (sin placa)

- El DTB de la DE10 compilado desde 912aa56 es idéntico byte a byte al que trae el
  `zImage_dtb` oficial 20260912 → mismo kernel que el release.
- `MiSTer` pide las mismas librerías que el oficial (+ libdl, que está en el linux.img) y
  como máximo GLIBC_2.29.
- Imagen de 1 GB: p1 exFAT con todos los ficheros (cmp contra el origen), p2 A2 = uboot.img.
- U-Boot sandbox (mismo árbol, con `host` en vez de `mmc`) sobre la imagen: carga
  `menu.rbf`, importa `u-boot.txt`, carga `zImage_dtb`, `fdt_addr` = 0x01835190 y el DTB
  se lee (`model`, `MiSTer_fb`, `reserved-memory`); la lógica `itest` del reinicio en caliente funciona.

## Actualizador (Distribution_MiSTer_ch96)

- `tools/build_db.py`: sources.ini → db.json.zip (git sin API; URLs fijadas al commit; sin cambios no reescribe).
- `tools/build_release.sh`: release_ch96_AAAAMMDD.7z + linux.json + system.json. Probado en local
  (20261120): kernel 6.18.38-MiSTer y DTB DE10 idénticos al oficial, MiSTer.version 261120.
- `tools/mk_mister_ch96_sd.sh`: ahora parte del release_ch96 (rechaza el release oficial).
- Workflows: `db.yml` (cada 6 h / push / repository_dispatch core_released), `release.yml` (manual).
- Cuando MiSTer saque linux.img nuevo: añadir `AAMMDD commit` en ch96/kernel_versions.txt.

## Instalador (mrfusion_ch96)

- `ch96/mrfusion/init` + `tools/build_mrfusion.sh`: imagen de ~165 MB (FAT32 MRFUSION + A2) que en
  el primer arranque amplía la tarjeta, instala MiSTer y reinicia. Binarios del linux.img oficial.
- El kernel de MiSTer no trae `BLK_DEV_INITRD`: el instalador usa un kernel aparte (mismo árbol, con
  initramfs dentro, `-MiSTer-installer`) y un DTB sin la reserva de 256 MB (Linux ve 512 MB).
- Probado en qemu vexpress-a9 (`tools/test_mrfusion_qemu.sh`) con tarjetas de 2 y 8 GB: reparticiona,
  formatea, descomprime y graba la A2; ficheros idénticos al paquete. U-Boot sandbox: arranca el
  instalador desde la FAT32 y la tarjeta instalada desde el exFAT.
- [ ] Probar en la placa (en qemu el MMC es el pl181, no el dw_mmc de la ch96).
