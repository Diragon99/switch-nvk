#!/usr/bin/env bash
# Package NVK for Switch consumers as split static libs (matches winsys/build-exe-linktest.sh):
#   nvk-switch/lib/libnvk.a          — driver (link with --whole-archive)
#   nvk-switch/lib/libnvk_support.a  — Mesa support archives + winsys shims
#   nvk-switch/include/vulkan/       — Vulkan headers
# A single fat MRI of everything + --whole-archive duplicates members (nv_push/Rust).
#   docker run --rm -v "D:\switch-nvk:/work" -w /work switch-nvk-build bash package-nvk.sh
set -e

DKP=/opt/devkitpro
GCC=$DKP/devkitA64/bin/aarch64-none-elf-gcc
AR=$DKP/devkitA64/bin/aarch64-none-elf-ar
NM=$DKP/devkitA64/bin/aarch64-none-elf-nm
MB=/work/mb
OUT=/work/nvk-switch
OBJ=/tmp/nvk-pkg
mkdir -p "$OBJ" "$OUT/lib" "$OUT/include/vulkan"

ARCH="-march=armv8-a+crc+crypto -mtune=cortex-a57 -mtp=soft -fPIE"
INC="-I$DKP/libnx/include -I/opt/switch-cross-include -Imesa-25/include -Imesa-25/src/nouveau/drm -Iwinsys -Icompat"
DEFS="-D__SWITCH__ -D_GNU_SOURCE -D_DEFAULT_SOURCE -include /work/compat/switch_compat.h"

echo "=== [1/5] compiling winsys shims (drm_shim + libc shim + compat) ==="
$GCC -c winsys/drm_shim.c            -o "$OBJ/drm_shim.o"            $ARCH $DEFS $INC -O2
$GCC -c winsys/switch_libc_shim.c    -o "$OBJ/switch_libc_shim.o"    $ARCH $DEFS $INC -O2
$GCC -c compat/compat.c              -o "$OBJ/compat.o"              $ARCH $DEFS $INC -O2
$GCC -c winsys/nvk_loaderless_shim.c -o "$OBJ/nvk_loaderless_shim.o" $ARCH $DEFS $INC -O2

ARCHIVES="
  src/nouveau/codegen/libnouveau_codegen.a
  src/util/libmesa_util.a src/util/libmesa_util_sse41.a src/util/blake3/libblake3.a
  src/c11/impl/libmesa_util_c11.a
  src/nouveau/compiler/libnak.a src/nouveau/compiler/libnak_rs.a
  src/compiler/rust/libcompiler_c_helpers.a
  src/nouveau/headers/libnvidia_headers_c.a
  src/nouveau/nil/liblibnil.a src/nouveau/nil/liblibnil_format_table.a
  src/compiler/nir/libnir.a src/compiler/libcompiler.a
  src/nouveau/mme/libnouveau_mme.a src/nouveau/winsys/libnouveau_ws.a
  src/vulkan/util/libvulkan_util.a src/compiler/spirv/libvtn.a
  src/util/libxmlconfig.a"

echo "=== [2/5] thickening libnvk.a (thin -> regular) ==="
NVK_IN="$MB/src/nouveau/vulkan/libnvk.a"
[ -f "$NVK_IN" ] || { echo "MISSING: $NVK_IN" >&2; exit 1; }
rm -rf "$OBJ/nvk-objs" && mkdir -p "$OBJ/nvk-objs"
# Thin archive members are absolute paths; copy them into a regular archive.
# Use sequential names: meson members like .._.._gallium_*.o are dotfiles and
# bash *.o skips them (that dropped tgsi_from_mesa and broke the dusk link).
n=0
while IFS= read -r m; do
  [ -f "$m" ] || { echo "MISSING member: $m" >&2; exit 1; }
  n=$((n + 1))
  cp -f "$m" "$OBJ/nvk-objs/$(printf 'm%04d.o' "$n")"
done < <($AR t "$NVK_IN")
[ "$n" -gt 0 ] || { echo "libnvk.a has no members" >&2; exit 1; }
rm -f "$OUT/lib/libnvk.a"
( cd "$OBJ/nvk-objs" && $AR rcs "$OUT/lib/libnvk.a" m*.o )
echo "  thickened $n objects"

echo "=== [3/5] MRI-merging support archives + shims -> libnvk_support.a ==="
TMPA="$OBJ/libnvk_support.a"
rm -f "$TMPA" "$OUT/lib/libnvk_support.a"
{
  echo "CREATE $TMPA"
  for a in $ARCHIVES; do
    [ -f "$MB/$a" ] || { echo "MISSING ARCHIVE: $MB/$a" >&2; exit 1; }
    echo "ADDLIB $MB/$a"
  done
  echo "ADDMOD $OBJ/drm_shim.o"
  echo "ADDMOD $OBJ/switch_libc_shim.o"
  echo "ADDMOD $OBJ/compat.o"
  echo "ADDMOD $OBJ/nvk_loaderless_shim.o"
  echo "SAVE"
  echo "END"
} | $AR -M
$AR s "$TMPA"
cp -f "$TMPA" "$OUT/lib/libnvk_support.a"
# Compat alias for older consumers expecting libvulkan.a (= nvk + support is wrong to MRI;
# keep a copy of support name only — dusklight uses FindNXVK split layout).

echo "=== [4/5] staging Vulkan headers -> $OUT/include/vulkan ==="
for h in vulkan.h vulkan_core.h vk_icd.h vk_platform.h vulkan_vi.h vk_android_native_buffer.h; do
  if [ -f "mesa-25/include/vulkan/$h" ]; then
    cp "mesa-25/include/vulkan/$h" "$OUT/include/vulkan/$h"
  else
    echo "  (note: mesa-25/include/vulkan/$h not found)"
  fi
done
if [ -d mesa-25/include/vk_video ]; then
  rm -rf "$OUT/include/vk_video"; cp -r mesa-25/include/vk_video "$OUT/include/vk_video"
fi

echo "=== [5/5] VERIFY symbols (nm) ==="
echo "--- ICD entry (libnvk): ---"
$NM "$OUT/lib/libnvk.a" 2>/dev/null | grep -E ' T vk_icdGetInstanceProcAddr$' | head || true
echo "--- wrap shims (libnvk_support): ---"
$NM "$OUT/lib/libnvk_support.a" 2>/dev/null | grep -E ' T (__wrap_open|__wrap_close)$' | sort -u || true
echo -n "libnvk.a size          : "; du -h "$OUT/lib/libnvk.a" | cut -f1
echo -n "libnvk_support.a size  : "; du -h "$OUT/lib/libnvk_support.a" | cut -f1
echo "=== PACKAGE DONE -> $OUT ==="
ls -la "$OUT/lib" "$OUT/include/vulkan"
