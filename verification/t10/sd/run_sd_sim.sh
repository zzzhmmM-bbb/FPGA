#!/bin/sh
# Reproduce the bmp_read fast-locate simulations (Git Bash). Work dir: /tmp/sdfast.
#   sh run_sd_sim.sh <txn|spi> <new|orig> <scenario> [extra plusargs]
# scenarios (built by make_sd_images.py): A2048 A8192 A8192_spc64_gap B_raw
#   C_badbpb D_fatregion E_superfloppy
# "orig" = T9 bmp_read.v (needs T9_DIR), compiled unmodified in place of the new one.
# txn: sd_txn_top.sv replaces sd_card_top..spi_master (transaction-level, fast).
# spi: real SD stack + sd_spi_card.sv on the SPI pins (slow; use +STOP=first).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
T10=$(cd "$HERE/../../.." && pwd)
T9="${T9_DIR:-}"   # orig mode only: set T9_DIR to the T9 package root
IV="${ICARUS_BIN:?set ICARUS_BIN to the Icarus bin directory}"
SD="$T10/project/main/src/user_source/hdl_source/SD"
W=/tmp/sdfast; mkdir -p "$W"
mode=$1; ver=$2; scen=$3; shift 3
[ -d "$W/img/$scen" ] || "${PY:-python}" -I -X utf8 "$HERE/make_sd_images.py" "$T10/assets/tf_card" "$W/img"
if [ "$ver" = orig ]; then BR="$T9/project/main/src/user_source/hdl_source/SD/bmp_read.v"; else BR="$SD/bmp_read.v"; fi
if [ "$mode" = spi ]; then
  "$IV/iverilog.exe" -g2012 -DSPI -o "$W/run_${mode}_$ver.vvp" -s tb_sd_card_bmp "$HERE/tb_sd_card_bmp.sv" \
    "$HERE/sd_spi_card.sv" "$HERE/sd_image_store.sv" "$SD/sd_card_bmp.v" "$BR" "$SD/sd_card_top.v" \
    "$SD/sd_card_cmd.v" "$SD/sd_card_sec_read_write.v" "$SD/spi_master.v"
else
  "$IV/iverilog.exe" -g2012 -o "$W/run_${mode}_$ver.vvp" -s tb_sd_card_bmp "$HERE/tb_sd_card_bmp.sv" \
    "$HERE/sd_txn_top.sv" "$HERE/sd_image_store.sv" "$SD/sd_card_bmp.v" "$BR"
fi
"$IV/vvp.exe" -n "$W/run_${mode}_$ver.vvp" +IMG="$W/img/$scen" +TAG="${mode}_${scen}_$ver" \
  +ADDRLOG="$W/addr_${mode}_${scen}_$ver.txt" "$@"
