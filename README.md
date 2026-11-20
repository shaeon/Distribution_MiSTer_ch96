# Distribution_MiSTer_ch96

Distribución de MiSTer para la **Chameleon96**: la SD y las actualizaciones
funcionan igual que en la DE10-Nano, con el `Scripts/update.sh` (Downloader)
oficial de MiSTer.

Este repositorio es, para la Chameleon96, lo que
[Distribution_MiSTer](https://github.com/MiSTer-devel/Distribution_MiSTer) es
para la DE10-Nano: publica un `db.json.zip` con los cores, el `menu.rbf`, el
binario `MiSTer` y el Linux propios de la placa.

## Cómo funciona

```
 repos de cores ──(releases/<Core>_ch96_AAAAMMDD.rbf)──┐
 teiram/Menu_MiSTer_ch96 ──(releases/menu_ch96_*.rbf)──┤
                                                        ├─> tools/build_db.py ─> db.json.zip
 release_ch96_AAAAMMDD (GitHub Releases) ───────────────┘          ▲
   linux.json  (kernel, U-Boot y linux.img)                         │
   system.json (MiSTer)                                  .github/workflows/db.yml
                                                         (cada 6 h, al cambiar sources.ini
                                                          o a mano)

 SD de la Chameleon96:
   /media/fat/downloader.ini  ->  [distribution_mister] db_url = este db.json.zip
   Scripts/update.sh          ->  el Downloader oficial, sin cambios
```

En la SD, `downloader.ini` sustituye la URL de `[distribution_mister]`. El
Downloader solo usa esa base de datos, así que nunca instala nada de la
DE10-Nano (cuyo kernel, U-Boot, `MiSTer` y `menu.rbf` dejarían la Chameleon96
sin arrancar).

- **Cores**: los `.rbf` se quedan en sus repositorios. La URL de la base de
  datos apunta al fichero fijado a su commit. Al instalar se quita el `_ch96`
  del nombre (`TS2068_ch96_20261117.rbf` → `_Computer/TS2068_20261117.rbf`), y
  cuando sale una fecha nueva el Downloader borra la anterior.
- **Linux**: el paquete `release_ch96_AAAAMMDD.7z` tiene la estructura del
  release oficial. El Downloader lo instala con el mismo `linux/updateboot` de
  MiSTer, que graba `uboot.img` en la partición 2 (la A2 de la SD).
  `/MiSTer.version` del `linux.img` lleva la fecha del paquete (AAMMDD) para
  que el Downloader sepa si está al día.

## Añadir un core

Añade una sección en `sources.ini` y haz push:

```ini
[TS2068]
repo    = Maverick-Shark/TS2068_MiSTer
branch  = ch96
folder  = _Computer
```

El workflow busca en `releases/` el `TS2068_ch96_*.rbf` más reciente. Las
versiones nuevas de los cores ya listados se recogen solas cada 6 horas. Para
que se publiquen al momento, el repositorio del core puede lanzar
`repository_dispatch` (tipo `core_released`) contra este repositorio.

## Nueva versión de Linux / MiSTer

`Actions → Release (Linux + MiSTer) → Run workflow`. Compila:

| Pieza | Origen |
|---|---|
| `linux/linux.img` | el oficial que anuncia la base de datos de MiSTer |
| `linux/zImage_dtb` | `MiSTer-devel/Linux-Kernel_MiSTer`, el **mismo commit** que el `linux.img` (`ch96/kernel_versions.txt`), + `ch96/socfpga_cyclone5_chameleon96_mister.dts` |
| `linux/uboot.img` | `teiram/u-boot-socfpga` (rama `chameleon96`) + `ch96/u-boot-socfpga-chameleon96-mister.patch` |
| `MiSTer` | `teiram/Main_MiSTer_ch96`, con la toolchain de MiSTer (gcc 10.2) |
| `menu.rbf` | `teiram/Menu_MiSTer_ch96`, último `menu_ch96_*.rbf` |

y con eso el instalador `mrfusion_ch96_AAAAMMDD.img.zip`. Todo se publica en
la release.

El script se para si el kernel no encaja con el `linux.img`: comprueba que la
versión coincide con la de sus módulos y que el DTB de la DE10 compilado es
idéntico byte a byte al del release oficial.

Cuando MiSTer saque un `linux.img` nuevo, añade en `ch96/kernel_versions.txt`
la línea `AAMMDD <commit>` con el commit de `Linux-Kernel_MiSTer` con el que se
compiló (o pásalo en `kernel_ref` al lanzar el workflow).

En local: `tools/build_release.sh` (variables documentadas en el script).

## Crear la SD

**Lo normal: el instalador.** Descarga `mrfusion_ch96_AAAAMMDD.img.zip` de la
última release y grábalo con Etcher, Win32DiskImager o `dd`, en una tarjeta de
cualquier tamaño (mínimo 1 GB). Al encender la Chameleon96 con ella:

1. el instalador copia el paquete a la RAM (usa los 512 MB de la placa);
2. rehace la tarjeta como la de MiSTer: exFAT `MiSTer_Data` en **toda** la
   tarjeta y la A2 en los 4 MB del final;
3. descomprime los ficheros, graba el U-Boot en la A2 y reinicia en MiSTer.

Tarda 2-3 minutos. La pantalla se queda en negro hasta que sale el menú; el
progreso se ve en la consola serie (115200). Es lo mismo que hace
[Mr. Fusion](https://github.com/MiSTer-devel/mr-fusion) en la DE10-Nano.

Antes de encender, en la unidad `MRFUSION` que aparece en el PC se pueden
dejar ficheros en `extra/` (por ejemplo `extra/linux/wpa_supplicant.conf` o
cores): se copian a la SD al terminar. Ver `LEEME.txt` en la propia tarjeta.

Cómo está hecho: `ch96/mrfusion/init` va como initramfs dentro de un kernel
aparte (el mismo kernel MiSTer con initramfs activado). Los binarios
(`busybox`, `sfdisk`, `mkfs.exfat`) se sacan del `linux.img` oficial. U-Boot
arranca exactamente igual que en la SD final: carga `menu.rbf` y
`linux/zImage_dtb`, que en el instalador es ese kernel con un DTB sin la
reserva de memoria de MiSTer.

**Directamente en la tarjeta**, desde Linux o WSL2, sin pasar por el instalador:

```sh
sudo tools/mk_mister_ch96_sd.sh -r release_ch96_AAAAMMDD.7z /dev/sdX
```

Con las dos opciones la SD queda con `downloader.ini` y `MiSTer.ini`
(`video_mode=0`, 1280x720). Después, `Scripts → update` descarga los cores.

Si tu SD se hizo antes, sin `downloader.ini`: copia `downloader.ini` a la raíz
de la SD y devuelve `Scripts/.ch96_disabled/update.sh` a `Scripts/`. La
primera actualización instalará también el paquete de Linux.

### Probar el instalador sin la placa

```sh
sudo tools/test_mrfusion_qemu.sh release/mrfusion_ch96_AAAAMMDD.img 2G
```

Arranca el mismo initramfs en qemu (vexpress-a9, Cortex-A9) con la imagen
ampliada a 2 GB como SD, deja que instale y comprueba el resultado:
particiones, ficheros idénticos al paquete y U-Boot en la A2.

## Estructura

```
sources.ini                 cores publicados
downloader.ini              el que va en la raíz de la SD
db.json.zip                 base de datos (la genera el workflow)
linux.json, system.json     última release_ch96 (los genera el workflow)
ch96/                       DTS, parche de U-Boot, MiSTer.ini, kernel_versions.txt
ch96/mrfusion/              /init y LEEME.txt del instalador
tools/build_db.py           genera db.json.zip
tools/build_release.sh      genera release_ch96_AAAAMMDD.7z
tools/build_mrfusion.sh     genera el instalador mrfusion_ch96_AAAAMMDD.img
tools/test_mrfusion_qemu.sh prueba el instalador en qemu
tools/mk_mister_ch96_sd.sh  crea la SD directamente en la tarjeta
```

## Créditos

- Port de MiSTer a la Chameleon96 (Main, menú, U-Boot, kernel): Manuel Teira
  ([teiram](https://github.com/teiram)).
- Cores para la Chameleon96: Maverick ([Maverick-Shark](https://github.com/Maverick-Shark))
  y sus autores originales.
- MiSTer: Alexey Melnikov (Sorgelig) y colaboradores. Downloader: José Manuel
  Barroso (theypsilon). Mr. Fusion, en el que se basa el instalador: Michael
  Smith y colaboradores.
- Distribución, SD y actualizador para la Chameleon96: Shaeon (Carlos Palmero).

Hecho con la ayuda de Claude (Anthropic).
