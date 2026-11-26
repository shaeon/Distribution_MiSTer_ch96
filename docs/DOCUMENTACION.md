# MiSTer para la Chameleon96 — documentación del proceso

Distribución de MiSTer para la placa **Chameleon96** (Arrow/Novtech, Cyclone V SoC):
la misma tarjeta SD que usa MiSTer en la DE10-Nano (Linux, `MiSTer`, menú, cores,
`update.sh`...), cambiando solo las piezas que dependen de la placa.

Repositorio: <https://github.com/shaeon/Distribution_MiSTer_ch96>
Base: el trabajo de Manuel Teira (teiram) en
[chameleon96-workbench](https://github.com/teiram/chameleon96-workbench), `Main_MiSTer_ch96`,
`Menu_MiSTer_ch96`, `u-boot-socfpga` y `linux-socfpga` (rama `chameleon96`).

Estado (21/11/2026): **arranca en la placa** desde una tarjeta de 32 GB instalada con el
instalador `mrfusion_ch96`.

---

## 1. Lo que hay que saber de la placa

| | Chameleon96 | DE10-Nano (MiSTer) |
|---|---|---|
| FPGA / HPS | Cyclone V SE A6 + ARM Cortex-A9 doble | Cyclone V SE A6 + ARM Cortex-A9 doble |
| DDR del HPS | **512 MB** | 1 GB |
| HDMI | NXP **TDA19988**, por I²C2 del HPS (lo programa `MiSTer`) | ADV7513 |
| Red | **sin PHY Ethernet** (solo USB) | Ethernet integrada |
| WiFi / BT | BCM4343W conectado a **pines de la FPGA** (no al HPS) | — |
| Arranque | SD (Boot ROM del HPS, como la DE10) | SD |

Reparto de la memoria (512 MB):

| Rango | Uso |
|---|---|
| 0x00000000–0x0FFFFFFF | Linux (256 MB) |
| 0x10000000–0x1FFFFFFF | reservado (`no-map`) en el DTS: ventana de los cores (ao486 en 0x10000000), framebuffer de MiSTer en 0x1D000000, página de avisos U-Boot↔`MiSTer` en 0x1FFFF000 |

Interruptores: el DIP **SW3** solo tiene `FORCE_USB_HUB` y `FORCE_nPOWER_ON`. MSEL lo pone el
CPLD (MAX II) y BOOTSEL va por resistencias: no hay nada que cambiar para arrancar desde la SD.
Detalle en el documento `interruptores_ch96.md` del proyecto.

---

## 2. La tarjeta SD

```
sector 0        MBR
sector 2048     p2  tipo A2, 4 MB   SPL + U-Boot (uboot.img)
sector 10240    p1  exFAT "MiSTer_Data", resto de la tarjeta
```

- Igual que en MiSTer, **p1 es el exFAT y p2 la A2** (lo que esperan `root=/dev/mmcblk0p1` y
  `linux/updateboot`, que graba `uboot.img` en `/dev/mmcblk0p2`).
- La A2 va **al principio** (1 MB), como en el workbench de teiram. En MiSTer va al final; las
  dos formas son válidas (es la misma Boot ROM), pero se dejó al principio porque es la que se
  sabe que funciona en esta placa.

Contenido del exFAT (como en MiSTer):

```
menu.rbf                 menú (core de la FPGA del menú)
MiSTer                   programa principal (Main_MiSTer_ch96)
MiSTer.ini               con video_mode=8 (1920x1080@60)
downloader.ini           apunta update.sh a la base de datos de la ch96
linux/linux.img          sistema Linux de MiSTer (oficial + firmware de red)
linux/zImage_dtb         kernel de MiSTer + DTB de la Chameleon96
linux/uboot.img          SPL + U-Boot (copia de lo que hay en la A2)
linux/u-boot.txt, updateboot, ch96_build.txt ...
Scripts/                 update.sh, wifi.sh, samba_on.sh..., update_extras.sh
_Computer/, _Arcade/ ... cores (los instala update.sh)
```

---

## 3. Cómo arranca

1. **Boot ROM** (dentro del HPS): lee el MBR, busca la partición de tipo **0xA2** y carga el
   **SPL** (preloader) de su principio en la OCRAM. Hay 4 copias de 64 KB, con cabecera
   `0x31305341` y CRC.
2. **SPL**: inicializa la DDR y carga **U-Boot** desde la A2 (desplazamiento 0x40000).
3. **U-Boot** (entorno de MiSTer, igual que la DE10):
   - `load mmc 0:1 menu.rbf` → `fpga load`: carga el menú en la FPGA.
   - Importa `linux/u-boot.txt` si existe (para personalizar).
   - `load mmc 0:1 linux/zImage_dtb` → `bootz` con el DTB pegado detrás del kernel.
   - `root=/dev/mmcblk0p1 loop=linux/linux.img`.
4. **Linux** (kernel de MiSTer): monta el exFAT, monta `linux.img` como raíz por loop y arranca
   `/media/fat/MiSTer`.
5. **MiSTer** (Main): programa el HDMI (TDA19988), muestra el menú y carga los cores.

En la consola serie se ve cada paso: `U-Boot SPL` → `U-Boot` → `bytes read` (menu.rbf y
zImage_dtb) → `Starting kernel ...` → arranque de Linux.

**Consola serie**: 115200 baudios, 8N1, sin control de flujo (`ttyS0`).

---

## 4. Las piezas y de dónde salen

| Fichero | Origen | Cambios |
|---|---|---|
| `linux/linux.img` | release oficial de MiSTer (20260912) | +16 MB y firmware `rtl_nic`; `MiSTer.version` = AAMMDD |
| `linux/zImage_dtb` | `MiSTer-devel/Linux-Kernel_MiSTer`, el mismo commit que el release oficial (para que valgan sus módulos) | `ch96/kernel.fragment` (red USB) + DTB de la ch96 |
| DTB | `ch96/socfpga_cyclone5_chameleon96_mister.dts`: DTS de teiram + nodos de MiSTer de la DE10 | ver §4.1 |
| `linux/uboot.img` | `teiram/u-boot-socfpga` rama `chameleon96` | `ch96/u-boot-socfpga-chameleon96-mister.patch` (ver §4.2) |
| `MiSTer` | `teiram/Main_MiSTer_ch96`, compilado con gcc 10.2 (glibc del linux.img) | `ch96/Main_MiSTer_ch96-*.patch` (ver §4.3) |
| `menu.rbf` | `teiram/Menu_MiSTer_ch96`, último `releases/menu_*_ch96.rbf` | — |
| Scripts | distribución oficial de MiSTer | — |
| `Scripts/update_extras.sh` | `ch96/Scripts/` de este repositorio | BIOS y ROMs de arcade (ver §BIOS y ROMs) |

### 4.1 DTS

Base: el DTS de la Chameleon96 de teiram (el de Manivannan Sadhasivam de 2018 + las reservas de
memoria de teiram). Añadido de la DE10 de MiSTer:

- `MiSTer_fb` en 0x1D000000 con IRQ `<0 40 1>`.
- Puentes FPGA, `flags-sram` en la OCRAM.
- usb1 en modo host con `disable-over-current`; uart sin DMA; i2c2 a 100 kHz (TDA19988).
- `spi-audio` en `&spi0` (sonido de Linux), igual que en la DE10. Ver §8.1.
- Sin `gmac` (no hay PHY) y sin LEDs GPIO (van por la FPGA).

### 4.2 Patch de U-Boot

- Entorno de arranque de MiSTer (el de la DE10): `menu.rbf`, `u-boot.txt`, `zImage_dtb`,
  reinicio en caliente del core.
- `mt` (comando propio del U-Boot de MiSTer) cambiado por `itest.l`.
- `CONFIG_ENV_IS_NOWHERE`: siempre el entorno por defecto.
- Pinmux: el SPI0 del HPS (SPIM0) va a la FPGA (`SPIM0USEFPGA = 1`, GENERALIO9-12 libres), como
  en el U-Boot de MiSTer para la DE10. teiram lo tenía sacado a los pines del conector de
  expansión. Hace falta para el sonido de Linux (§8.1).
- `board_get_usable_ram_top()` = 0x10000000, para que U-Boot no se coloque encima de la página
  de avisos de 0x1FFFF000.
- **exFAT** (`CONFIG_FS_EXFAT=y`) con tres arreglos del código exFAT de U-Boot en 32 bits:
  1. `fs/exfat/time.c`: división de 64 bits con signo → sin signo (no enlazaba, faltaba
     `__aeabi_ldivmod`).
  2. `fs/exfat/io.c`: el tamaño de la partición se calculaba en 32 bits y se desbordaba en
     cuanto la partición pasaba de 4 GB.
  3. `fs/exfat/node.c`: la etiqueta del volumen se convertía entera (15 caracteres) en vez de
     solo los válidos; con basura detrás, no montaba.

### 4.3 Patch del Main: teclado como joystick por defecto

Los cores con `J1` en el CONF_STR (arcades y consolas) ponen el teclado en modo "joystick 1",
pero en MiSTer el teclado no tiene botones hasta que se definen en el OSD, y el mapeo se guarda
por modelo de teclado (`config/inputs/<core>_input_<vid>_<pid>_v4.map`). Con una tarjeta nueva
no se podían meter monedas en Galaga.

`ch96/Main_MiSTer_ch96-teclado-joystick.patch`: si el teclado no tiene botones definidos, usa
este mapeo estándar (las teclas de MAME), que se reparte por los nombres de botón de cada core
como en MiSTer:

| Botón estándar | Tecla | En los arcades |
|---|---|---|
| Cruceta | cursores | |
| A, B, X, Y | Ctrl izq., Alt izq., Espacio, Mayús izq. | Fire = A |
| Start | `1` | Start 1P |
| Select | `2` | Start 2P |
| R | `5` | Coin |
| L | `P` | Pause (Galaga) |

Si el usuario define los botones del teclado (en el menú o en el core), manda lo suyo.
`build_release.sh` aplica todos los `ch96/Main_MiSTer_ch96-*.patch` al Main de teiram.

---

## 5. El repositorio

```
sources.ini                  qué cores entran en la base de datos (§6)
db.json.zip                  base de datos para update.sh (la genera db.yml)
linux.json, system.json      versión de Linux y de MiSTer publicadas (las genera release.yml)
downloader.ini               se copia a la SD
ch96/
  socfpga_cyclone5_chameleon96_mister.dts
  u-boot-socfpga-chameleon96-mister.patch
  Main_MiSTer_ch96-teclado-joystick.patch
  kernel.fragment            opciones del kernel añadidas (red USB)
  kernel_versions.txt        "AAMMDD commit" del kernel de cada linux.img oficial
  MiSTer.ini
  mrfusion/init              programa del instalador
tools/
  build_db.py                sources.ini → db.json.zip
  build_release.sh           compila kernel, U-Boot y MiSTer y arma el release
  build_mrfusion.sh          arma el instalador
  mk_mister_ch96_sd.sh       graba una SD desde un PC Linux
  test_mrfusion_qemu.sh      prueba el instalador en qemu
.github/workflows/
  db.yml                     "Base de datos": cada 6 h, al hacer push y por repository_dispatch
  release.yml                "Release (Linux + MiSTer)": manual
PROGRESO.md                  bitácora de trabajo
```

### Workflows

- **Base de datos** (`db.yml`): ejecuta `build_db.py` y sube `db.json.zip` si ha cambiado. Se
  lanza cada 6 horas, al cambiar `sources.ini` y con `repository_dispatch` de tipo
  `core_released` (para que un repo de core avise al publicar).
- **Release (Linux + MiSTer)** (`release.yml`, manual): ejecuta `build_release.sh` y
  `build_mrfusion.sh` y publica tres ficheros:
  - `release_ch96_AAAAMMDD.7z`: paquete de Linux (lo que descarga `update.sh`).
  - `MiSTer_ch96_AAAAMMDD`: el programa `MiSTer`.
  - `mrfusion_ch96_AAAAMMDD.img.zip`: el instalador.

  Luego sube `linux.json`, `system.json` y `db.json.zip`. La versión es la fecha del día: si se
  lanza dos veces el mismo día, sale con la misma versión.
- Todas las acciones son de **Node 24** (`actions/checkout@v6`, `actions/cache@v5`...).
- Los commits van a nombre de **Shaeon (Carlos Palmero)**.

### Cuándo hay que lanzar Release

- Cambios en U-Boot, el DTS, el kernel o el instalador.
- Nuevo `Main_MiSTer_ch96` o nuevo menú de teiram.
- Nuevo `linux.img` oficial de MiSTer: primero añadir `AAMMDD commit` en
  `ch96/kernel_versions.txt` (el commit de `Linux-Kernel_MiSTer` de ese release).

Para añadir o actualizar cores **no** hace falta: basta con la base de datos.

---

## 6. Actualizador y cores

`update.sh` es el Downloader oficial de MiSTer. `downloader.ini` en la SD le cambia la URL de la
base de datos `distribution_mister` por la de este repositorio:

```ini
[distribution_mister]
db_url = https://raw.githubusercontent.com/shaeon/Distribution_MiSTer_ch96/main/db.json.zip
```

La base de datos incluye `MiSTer`, `menu.rbf`, el paquete de Linux (campo `linux`, que el
Downloader instala y graba con `updateboot`), los scripts y los cores.

### `sources.ini`

Cada sección es un core:

```ini
[ao486]
repo    = teiram/ao486_MiSTer_ch96
branch  = master          ; opcional: por defecto la rama principal
folder  = _Computer       ; opcional: por defecto _Computer (_Arcade/cores en los arcades)
oficial = games/AO486/*   ; opcional: ficheros de apoyo copiados de la distribución oficial
```

- `build_db.py` toma el `.rbf` más reciente de `releases/` que acabe en **`_AAAAMMDD_ch96.rbf`**
  (formato actual de teiram) o **`_ch96_AAAAMMDD.rbf`** (antiguo). Los `.rbf` sin `_ch96` son los
  de la DE10 y se ignoran.
- Se instala **con el `_ch96` al final**, detrás de la fecha, para que en la SD se vea que el core
  es de la Chameleon96: `ao486_20261120_ch96.rbf` → `_Computer/ao486_20261120_ch96.rbf`. El formato
  antiguo se reordena: `TS2068_ch96_20261117.rbf` → `TS2068_20261117_ch96.rbf`. El menú de MiSTer
  corta el nombre en el primer `_20` (`file_io.cpp`), así que muestra «ao486» con su fecha y no
  enseña el sufijo; el `_ch96` delante de la fecha sí saldría en el nombre. Cuando sale una fecha
  nueva el Downloader borra la anterior (y en las SD con los nombres sin `_ch96` de antes del
  25/11/2026, los cambia solo en el siguiente `update`).
- Las URL quedan fijadas al commit (`raw.githubusercontent.com/<repo>/<sha>/releases/...`).
- **Arcades**: si la sección empieza por `Arcade-`, el `.rbf` va a `_Arcade/cores/` **sin el
  `Arcade-`** (`Galaga_20261120_ch96.rbf`: `<rbf>galaga</rbf>` en los `.mra` busca `galaga_*.rbf`, `mra_loader.cpp`), y
  los `releases/*.mra` del mismo commit van a `_Arcade/`. Las ROMs (`games/mame/*.zip`) las pone
  cada usuario.
- `[oficial]`: scripts copiados tal cual de la distribución oficial (`Scripts/` de
  `MiSTer-devel/Distribution_MiSTer`: update, wifi, samba_on, timezone, ini_settings y
  fast_USB_polling; `rtc.sh` no, porque es para la placa RTC de la DE10). `[menu]`: `menu.rbf`.
- `ficheros`: ficheros sueltos de cualquier repositorio (`origen -> destino`), fijados a su
  último commit. Se usa para los scripts de MidiLink (`soundfont_install.sh` y
  `midilink_updater.sh`, de `MiSTer-devel/MidiLink_MiSTer`), que en MiSTer no vienen en la
  distribución oficial, y para los scripts propios de la ch96 (`[ch96-scripts]`, que coge
  `ch96/Scripts/` de este mismo repositorio). `build_release.sh` mete además `ch96/Scripts/*.sh`
  en el paquete, para que vengan ya en la SD.

### BIOS y ROMs de arcade: `Scripts/update_extras.sh`

`update_all` no vale en la ch96: instalaría la distribución de la DE10 y la placa dejaría de
arrancar. `update_extras.sh` hace lo que hace `update_all` en «Extra Content» con dos bases de
datos, pero llamando al Downloader oficial (`Scripts/update.sh`):

| Base de datos | Origen |
|---|---|
| `bios_db` | `ajgowans/BiosDB_MiSTer` |
| `arcade_roms_db` | `zakk4223/ArcadeROMsDB_MiSTer` |

1. Mira los `.rbf` de `_Computer`, `_Console`, `_Other`, `_Utility` y `_Arcade/cores` y saca el
   nombre de cada core sin fecha ni `_ch96`, normalizado como las etiquetas del Downloader.
2. Escribe `Scripts/.config/update_extras/downloader.ini` con esas dos bases de datos y un
   `filter =` en cada una (`<core>` en `bios_db`, `arcade<core>` en `arcade_roms_db`), y lanza el
   Downloader con `DOWNLOADER_INI_PATH` apuntando ahí, `ALLOW_REBOOT=0` y `UPDATE_LINUX=false`.
   Como ese ini no tiene `[distribution_mister]`, no toca cores, `MiSTer`, `menu.rbf` ni Linux.
3. Al terminar revisa los `zip="..."` de los `.mra` instalados y avisa de las ROMs que falten
   (solo aviso).

Los alias entre el nombre del core y la etiqueta de `bios_db` están en la función `aliases()`
del script (en la ch96 «Lynx» es el Camputers Lynx: no lleva alias a `atarilynx`).

Comprobado con el Downloader 2.4 en modo PC sobre una SD simulada:

- Solo escribe en `games/` y en `Scripts/.config/`. El almacén del Downloader
  (`Scripts/.config/downloader/downloader.json`) es el mismo que el de `update.sh`: después,
  `Scripts → update` no borra las ROMs y `update_extras` no borra los cores.
- Si se borra un core y se vuelve a lanzar `update_extras`, el Downloader borra las ROMs/BIOS que
  había bajado para ese core (las que pone cada uno a mano no las toca).
- Los términos del filtro sin ficheros (cores sin BIOS, como `ao486` u `osborne`) salen como
  «Unused filter terms»: es normal.

### Filtros

Cada fichero de la base de datos lleva etiquetas con los mismos nombres que la distribución
oficial, así que valen los mismos filtros del Downloader que en MiSTer. Se ponen en
`downloader.ini`, en la sección `[distribution_mister]` (o en `[mister]` para todas):

```ini
[distribution_mister]
db_url = https://raw.githubusercontent.com/shaeon/Distribution_MiSTer_ch96/main/db.json.zip
filter = computer !ao486
```

| Etiqueta | Qué lleva |
|---|---|
| `essential` | `MiSTer`, `menu.rbf`, `update.sh` (se instalan siempre) |
| `cores` | todos los `.rbf` |
| `computer` (`computercores`), `arcade` (`arcadecores`)... | por carpeta |
| nombre del core: `ao486`, `amstradpcw`, `osborne`, `arcadegalaga`... | el core y sus ficheros |
| `mra`, `arcaderbfsonly` | los `.mra` y los `.rbf` de los arcades |
| `scripts` y el nombre del script (`wifi`, `soundfontinstall`...) | `Scripts/` |
| `games`, `bios`, `palettes`... | ficheros de apoyo copiados de la oficial (con sus etiquetas) |

Los `.mra` y los ficheros copiados de la oficial conservan sus etiquetas (orientación de
pantalla, controles...). Los alias (`computer` = `computercores`...) también salen de la oficial.
Probado con el Downloader 2.4 en modo PC: `filter = osborne scripts` instala solo el Osborne, los
scripts y lo esencial; `filter = arcade`, solo los arcades y lo esencial.

Cores actuales:

| Sección | Repositorio |
|---|---|
| ao486, Amstrad, Amstrad-PCW, BBCMicro, MicroBee, PET2001, SharpMZ | `teiram/<core>_MiSTer_ch96` |
| TI-99_4A | `teiram/TI-99_4A_MiSTer_ch96` (`pattern = Ti994a_*_ch96.rbf`) |
| Microtan65 | `teiram/Microtan65_ch96` |
| Arcade-Galaga, Arcade-Gaplus, Arcade-QBert | `teiram/Arcade-<core>_MiSTer_ch96` |
| TS2068 | `Maverick-Shark/TS2068_MiSTer`, rama `ch96` |
| PCAT-286 | `Maverick-Shark/pcat-286_mister`, rama `ch96` |
| IMSAI8080 | `shaeon/IMSAI8080_MiSTer`, rama `ch96` |
| Osborne | `shaeon/Osborne_MiSTer_ch96` |
| Lynx | `shaeon/Lynx_MiSTer_ch96` |
| TatungEinstein | `shaeon/TatungEinstein_ch96` |

Para añadir uno: nueva sección en `sources.ini` → push. En el siguiente `update.sh` aparece en la
placa.

---

## 7. Instalador (mrfusion_ch96)

Imagen pequeña (~165 MB) que se graba con Etcher en cualquier tarjeta:

- p1 FAT32 `MRFUSION`: `menu.rbf`, `linux/zImage_dtb` del instalador, `mrfusion/payload.tar.xz`
  (todo el exFAT comprimido), `extra/` y `LEEME.txt`.
- A2 con el mismo `uboot.img` del release.

En el primer arranque, el kernel del instalador (initramfs con busybox, sfdisk y mkfs.exfat
sacados del `linux.img`):

1. Copia el paquete a la RAM.
2. Reparticiona toda la tarjeta (A2 + exFAT) y formatea el exFAT `MiSTer_Data`.
3. Descomprime el paquete y copia `extra/` (para meter ficheros propios en la imagen).
4. Graba `uboot.img` en la A2 y reinicia en MiSTer.

El kernel de MiSTer no trae `BLK_DEV_INITRD`, así que el instalador usa otro kernel (mismo árbol,
con el initramfs dentro) y un DTB sin la reserva de 256 MB.

Se prueba en qemu con `tools/test_mrfusion_qemu.sh`.

---

## 8. Red y SSH

- La placa no tiene Ethernet: se usa un **adaptador USB**. El kernel lleva RTL8152/8153/8156,
  ASIX AX88772/AX88179, CDC ECM/NCM y RNDIS, y el `linux.img` lleva el firmware `rtl_nic`.
- WiFi: adaptadores USB compatibles con MiSTer (`Scripts/wifi.sh`).
- SSH: `ssh root@<ip>`, contraseña `1` (como en MiSTer). Samba: `Scripts/samba_on.sh`.
- La WiFi integrada (BCM4343W) está conectada a la FPGA y no al HPS. Usarla necesitaría un
  controlador SDIO en el framework de cada core. Está estudiado en `wifi_bt_integrados_ch96.md`
  y no está hecho.

### 8.1 Sonido de Linux: MIDI del ao486 (MidiLink), MP3...

En MiSTer, el ao486 manda el MIDI por la UART a Linux (`/dev/ttyS1`), MidiLink lo pasa a
FluidSynth (General MIDI, con soundfont) o a MUNT (MT-32), y el audio que generan sale por la
tarjeta de sonido de MiSTer (driver `MiSTer,spi-audio`). Ese driver deja el audio en un búfer de
la RAM de Linux y le pasa su dirección a la FPGA por el SPI0 del HPS. El módulo `alsa.sv` del
framework lo lee de la DDR y lo mezcla con el sonido del core.

Para que funcione en la ch96 hacen falta tres cosas:

| Pieza | Dónde | Estado |
|---|---|---|
| Nodo `spi-audio` en `&spi0` | DTS (este repo) | hecho |
| SPIM0 del HPS hacia la FPGA (`SPIM0USEFPGA = 1`) | pinmux de U-Boot (este repo) | hecho |
| `alsa.sv` y el SPI en el core: sin `MISTER_DISABLE_ALSA` y con la asignación `HPS_LOCATION ... SPIMASTER` en `sys/hps_ch96.tcl` | cada core (teiram) | **pendiente** |

Mientras los cores se compilen con `MISTER_DISABLE_ALSA=1` (todos los de la ch96 a 23/11/2026),
MidiLink no suena. El OPL3 (AdLib/Sound Blaster) del ao486 no depende de Linux y sí suena.

---

## 9. Instalar en una tarjeta

1. Descargar `mrfusion_ch96_AAAAMMDD.img.zip` del último release.
2. Grabarlo con Etcher (o Rufus, o `dd`) en la tarjeta.
3. Arrancar la Chameleon96 con la tarjeta. El instalador tarda unos 2 minutos y reinicia solo.
4. Con red: `Scripts → update` para bajar los cores.

### Grabar solo U-Boot en una tarjeta ya instalada

Sirve para probar un `uboot.img` nuevo sin reinstalar.

**Linux:**
```
lsblk                                   # la A2 es la partición 2, de 4 MB
sudo dd if=uboot.img of=/dev/sdX2 bs=64k conv=fsync
sudo cmp -n $(stat -c%s uboot.img) uboot.img /dev/sdX2 && echo OK
```

**Windows (Git Bash como administrador):**
```
cat /proc/partitions                    # buscar el disco de la tarjeta: sdX1 grande y sdX2 de 4096 bloques
md5sum uboot.img
dd if=uboot.img of=/dev/sdX2 bs=64k
sync
head -c $(stat -c%s uboot.img) /dev/sdX2 | md5sum   # tiene que coincidir
```
**Nunca** `sda`, que suele ser el disco de Windows. La fecha de la primera línea de la consola
serie (`U-Boot SPL ... (Nov 21 2026 - hh:mm:ss)`) dice qué U-Boot está arrancando.

---

## 10. Trabajar con el repositorio en un ordenador nuevo

```
git config --global user.name "Shaeon (Carlos Palmero)"
git config --global user.email "shaeon@users.noreply.github.com"
git config --global core.autocrlf false       # que Windows no cambie los saltos de línea
git clone https://github.com/shaeon/Distribution_MiSTer_ch96.git
cd Distribution_MiSTer_ch96
```

Para aplicar cambios que llegan como patch:
```
git pull --rebase           # siempre antes: los workflows suben commits (db.json.zip, releases)
git am 00xx-*.patch
git push
```

Si `git push` dice `rejected (fetch first)`, son commits de los workflows: `git pull --rebase` y
`git push` otra vez.

---

## 11. Bitácora de problemas

| Síntoma | Causa | Solución |
|---|---|---|
| U-Boot no enlazaba: `__aeabi_ldivmod` | división de 64 bits con signo en `fs/exfat/time.c` | sin signo (patch de U-Boot) |
| CI: `qemu-user-static` no existe | paquete renombrado en Ubuntu 24.04 | qemu opcional, `ubuntu-24.04` |
| CI: aviso de Node 20 | acciones antiguas | todas las acciones en Node 24 |
| CI: `Permission denied` en los scripts | se perdió el bit de ejecución al subir desde Windows | ejecutarlos con `bash` y marcarlos `+x` |
| CI: `no está /bin/busybox en el linux.img` | `/usr` del linux.img con permisos 770 de root | `build_mrfusion.sh` se relanza con `sudo` |
| CI: disco lleno | ficheros temporales | limpieza |
| Instalador: `unable to open an initial console` | faltaba `/dev/console` en el initramfs | `mknod /dev/console c 5 1` |
| Tras instalar no arrancaba (tarjeta de 128 GB) | se pensó que era la A2 al final; no lo era | A2 al principio (se deja así) |
| Teiram cambia el nombre de los `.rbf` a `_AAAAMMDD_ch96.rbf` | — | `build_db.py` y `build_release.sh` aceptan los dos formatos |
| U-Boot: `file system in sectors is larger than device` + `Can't set block device` | tamaño de la partición calculado en 32 bits (`fs/exfat/io.c`): con más de 4 GB se desborda | multiplicar en 64 bits |
| Imagen rara (720p) | `video_mode=0` copiado del workbench | `video_mode=8` (1080p60) |
| Galaga: no se pueden meter monedas con el teclado | en MiSTer el teclado no tiene botones de joystick hasta definirlos | mapeo estándar por defecto en el Main (§4.3) |
| MIDI del ao486 sin sonido (soundfonts y MidiLink bien) | no hay sonido de Linux en la ch96: DTS sin `spi-audio`, SPIM0 sacado a pines y cores con `MISTER_DISABLE_ALSA` | DTS y U-Boot arreglados; falta el core (§8.1) |
| U-Boot: `illegal UTF-16 sequence` + `Can't set block device` | U-Boot convertía los 15 caracteres de la etiqueta y el `mkfs.exfat` del linux.img (exfatprogs 1.0.4) deja basura detrás de `MiSTer_Data` | convertir solo los caracteres válidos (`fs/exfat/node.c`) |

Lecciones:

- El simulador de U-Boot (sandbox) es de 64 bits y no destapa los desbordamientos de 32 bits.
  Las pruebas de exFAT se hacen con U-Boot `qemu_arm` (32 bits), un disco del tamaño real y
  formateado con el **mismo** `mkfs.exfat` que usa el instalador (el del `linux.img`, ejecutado
  con `qemu-arm-static`).
- Antes de cambiar nada, pedir la **consola serie**: dice exactamente en qué paso se para.

Patches del repositorio, en orden: 0001–0005 (CI, red USB), 0006 (A2 al principio), 0007 (cores
y nombre nuevo), 0008 (arcades), 0009 (exFAT > 4 GB), 0010 (etiqueta exFAT), 0011 (esta documentación), 0012 (1080p60), 0013 (teclado como joystick), 0014 (Osborne), 0015 (scripts de MidiLink), 0016 (etiquetas para los filtros), 0017 (Lynx), 0018 (sonido de Linux: DTS y U-Boot).

---

## 12. Pendiente

- [ ] Comprobar en la placa el resto del arranque: Linux, `MiSTer`, HDMI, menú y carga de cores.
- [ ] Probar `update.sh` en la placa, incluida la actualización de Linux y de U-Boot (`updateboot`).
- [ ] Probar la red USB y SSH.
- [ ] Sonido de Linux: falta que los cores se compilen con ALSA (§8.1). Probar MidiLink en el ao486.
- [ ] WiFi/BT integrados: necesitan un controlador SDIO en la FPGA.

---

Agradecimientos: Manuel Teira (teiram) por el port de MiSTer a la Chameleon96, Maverick
(Maverick-Shark) por sus cores ch96 y MiSTer-devel por MiSTer.

Documentación, scripts y arreglos preparados con ayuda de Claude (Anthropic).
