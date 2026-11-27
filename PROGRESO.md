# SD de MiSTer para la Chameleon96 — progreso

Objetivo: misma SD que MiSTer en la DE10-Nano (exFAT `MiSTer_Data` + partición A2),
usando el `linux.img` oficial sin tocar y solo cambiando las piezas propias de la placa.

## Piezas

| Pieza | Origen | Estado |
|---|---|---|
| `linux/linux.img` | release oficial MiSTer 20260912 (sin cambios) | ok |
| `MiSTer` | teiram/Main_MiSTer_ch96 @ d9799de, gcc 10.2-2020.11 (glibc ≤ 2.29, el linux.img trae 2.31) | compilado |
| `menu.rbf` | teiram/Menu_MiSTer_ch96 último `releases/menu_*_ch96.rbf` | ok |
| `linux/uboot.img` | teiram/u-boot-socfpga rama chameleon96 @ 1d6a164 + `patches/u-boot-socfpga-chameleon96-mister.patch` | compilado |
| `linux/zImage_dtb` | MiSTer-devel/Linux-Kernel_MiSTer @ 912aa56 (6.18.38, el del release 20260912, para que encajen los módulos del linux.img) + `socfpga_cyclone5_chameleon96_mister.dts` | compilado (vermagic `6.18.38-MiSTer SMP mod_unload ARMv7 p2v8`, igual que los 94 módulos del linux.img) |
| `MiSTer.ini` | MiSTer_example.ini con `video_mode=8` (1080p60; antes 0 = 720p, como el workbench) | ok |
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
- [ ] WiFi integrada (BCM4343W por SDIO hacia la FPGA): necesita un controlador SDIO en la FPGA. De momento, WiFi USB.
- [x] Red USB por cable: ch96/kernel.fragment (RTL8152/8153/8156, ASIX, AX88179, CDC ECM/NCM, RNDIS) + firmware rtl_nic en el linux.img (ampliado 16 MB). SSH ya venía en el linux.img (root / 1).
- [ ] Sonido de Linux (spi-audio) desactivado en el sys de ch96.
- [x] Scripts/update_extras.sh (BIOS y ROMs de arcade de los cores instalados, bios_db + arcade_roms_db,
      sin update_all). Probado con el Downloader 2.4 en modo PC; falta probarlo en la placa.
- [ ] Parpadeo de la pantalla con los scripts en el terminal del framebuffer (fb_terminal=1) a 1080p:
      probar fb_size=2 y, si sigue, fb_terminal=0 (salida en el OSD) o video_mode=0.

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
- [x] Probado en la placa (tarjeta de 128 GB): el instalador instala, pero con la A2 en los últimos
      4 MB la Boot ROM no carga el preloader. Ahora la A2 va al principio (sector 2048, 4 MB) y el exFAT
      desde el sector 10240 (instalador, mk_mister_ch96_sd.sh y test). p1 = exFAT, p2 = A2 como antes.
- [ ] Volver a probar en la placa con la A2 al principio.

## Cores de teiram con el nombre nuevo (20/11/2026)
- teiram ha resintetizado los cores con `_ch96` detrás de la fecha (`ao486_20261120_ch96.rbf`,
  `menu_20261120_ch96.rbf`). build_db.py y build_release.sh aceptan los dos formatos; a igualdad
  de fecha gana el nuevo. Se instalan sin `_ch96`.
- sources.ini: ao486, Amstrad, Amstrad-PCW, BBCMicro, MicroBee, PET2001, SharpMZ (teiram),
  TS2068 (Maverick-Shark) e IMSAI8080 (shaeon, rama ch96).
- Campo `oficial` por core: copia de la base de datos oficial los ficheros de apoyo
  (games/AO486/*, games/Amstrad/*, games/Amstrad PCW/*, games/PET2001/*). Admite comodines.
- Amstrad y SharpMZ aún no tienen .rbf con el nombre nuevo: se coge el `_ch96_` antiguo.
- Probado build_db.py: 43 ficheros.

## Arcades (21/11/2026)
- teiram/Arcade-Galaga, Arcade-Gaplus y Arcade-QBert (_MiSTer_ch96). Se buscaron los 216 arcades de la
  distribución oficial con el prefijo teiram/Arcade-<core>_MiSTer_ch96: solo existen esos tres.
- Secciones Arcade-*: .rbf a _Arcade/cores/ sin "Arcade-" (Galaga_20261120.rbf, lo que pide <rbf>galaga</rbf>)
  y releases/*.mra del mismo commit a _Arcade/ (campo `mra`). Probado build_db.py: 53 ficheros; URLs de .mra con
  comillas y acento grave descargan con el md5 correcto.

## U-Boot no leía exFAT en tarjetas grandes (21/11/2026)
- Log de la placa (tarjeta de 32 GB): `file system in sectors is larger than device: 61061120 * 512 >
  1198522368` + `Can't set block device`. 1198522368 = 31263293440 - 7*2^32: en fs/exfat/io.c (rama U-Boot)
  `dev->size = part.size * part.blksz` multiplica dos ulong de 32 bits y se desborda en cuanto la partición
  pasa de 4 GB. En el sandbox (64 bits) no salía.
- Arreglo en ch96/u-boot-socfpga-chameleon96-mister.patch: `(off_t)` antes de multiplicar (off_t ya es de
  64 bits en la librería exfat de U-Boot).
- Probado con U-Boot qemu_arm (32 bits, sin SYS_64BIT_LBA) y un disco de 32 GB con la misma tabla que el
  instalador: el original da el mismo error que la placa; el arreglado lee linux/zImage_dtb, situado después
  de 6 GB de relleno, con el CRC32 correcto.
- La A2 al principio no era el problema (el instalador ya arrancaba con el mismo uboot.img), pero se deja:
  es también donde la pone teiram (offset 1 MB).

## U-Boot: etiqueta del exFAT (21/11/2026)
- Con el arreglo de los 4 GB la placa pasa a `illegal UTF-16 sequence` + `Can't set block device`.
- La entrada de etiqueta del exFAT tiene 15 caracteres y un contador (11 para MiSTer_Data). U-Boot convertía
  los 15 y solo paraba en un 0; el mkfs.exfat del linux.img (exfatprogs 1.0.4, el que usa el instalador) deja
  basura detrás de la etiqueta. Si la basura es medio par sustituto UTF-16, no monta.
- Arreglo en fs/exfat/node.c: copiar solo label->length caracteres y rellenar con ceros.
- Probado en qemu_arm con un exFAT de 32 GB formateado con ese mkfs.exfat (qemu-arm-static) y basura 0xD800
  en la etiqueta: el U-Boot anterior falla igual que la placa; el nuevo carga zImage_dtb.

## Teclado como joystick por defecto (21/11/2026)
- Galaga (y los arcades/consolas con J1): el teclado pasa a "joystick 1" pero sin botones hasta definirlos, y el
  mapeo se guarda por vid/pid del teclado, así que no vale un fichero en config/inputs.
- ch96/Main_MiSTer_ch96-teclado-joystick.patch (input.cpp): si un teclado no tiene botones definidos (su mmap es la
  de mando por defecto), map_joystick() parte de un mmap estándar: cursores, Ctrl/Alt/Espacio/Mayús = A/B/X/Y,
  1 = Start, 2 = Select, 5 = R (Coin), P = L. build_release.sh aplica ch96/Main_MiSTer_ch96-*.patch.
- Compila con gcc 10.2 sobre teiram/Main_MiSTer_ch96 d9799de. Sin probar en la placa.

## Nombre de los .rbf en la SD con _ch96 (25/11/2026)
- Se instalan como en los repos, con _ch96 al final: ao486_20261120_ch96.rbf, Galaga_20261120_ch96.rbf (sin
  "Arcade-"). El formato antiguo se reordena: TS2068_ch96_20261117.rbf -> TS2068_20261117_ch96.rbf.
- El menú (file_io.cpp) corta el nombre en el primer "_20": muestra "ao486" y la fecha, sin el sufijo. Los .mra
  (mra_loader.cpp) buscan "<rbf>_": encuentran Galaga_20261120_ch96.rbf.
- Probado con el Downloader 2.4 en modo PC: con la db anterior instala Osborne_20261122.rbf y Galaga_20261120.rbf;
  con la nueva los borra e instala los *_ch96.rbf. update_extras.sh ya quitaba el _ch96 al sacar el nombre.

## PCXT de Aitor (27/11/2026)
- [PCXT] en sources.ini: aitorgomez-net/PCXT_ch96. La distribución oficial solo tiene el .rbf y docs/PCXT,
  sin BIOS. Se copian de SW/ROMs/ del repo de Aitor a games/PCXT/ (pcxt_xtsergey, pcxt_pcxt31, ide_xtl y
  BASICA/) y pcxt_xtsergey.rom también como boot0.rom: Main_MiSTer la carga en la ranura 0 (PCXT BIOS)
  si no hay otra elegida en el OSD (user_io.cpp). boot1..3.rom no valen: van también a la ranura 0.
- [ ] Falta que Aitor suba releases/PCXT_AAAAMMDD_ch96.rbf (hoy releases/ solo tiene .gitkeep); hasta
      entonces build_db.py avisa y solo publica las ROMs.
- [ ] hd_image.zip (FreeDOS, 26 MB, games/PCXT del repo) no se publica: hay que descomprimirlo a mano.
