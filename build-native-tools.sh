#!/usr/bin/env bash
# M1 phase 1 (NATIVE): build + install the build-machine shader-compiler tools (mesa_clc and the
# nouveau precomp compiler) so the CROSS build can consume them via -Dmesa-clc=system
# -Dprecomp-compiler=system instead of (wrongly) cross-compiling LLVM/CLC/SPIRV-Tools FOR the Switch.
# This is the standard Mesa cross-compile-with-CLC recipe. Run once; the tools land in /usr/local/bin.
set -e
NB="${NB:-/work/native-tools}"
PREFIX="${NATIVE_PREFIX:-/work/native-prefix}"

# Idempotent: the prefix lives on the persistent /work mount, so once built the native tools
# survive across --rm containers — skip the (slow) x86 rebuild on subsequent runs.
if [ -x "$PREFIX/bin/mesa_clc" ] && [ -x "$PREFIX/bin/vtn_bindgen" ]; then
  echo "native tools already present at $PREFIX/bin (skipping rebuild)"
  exit 0
fi

# Pure native (x86) build — no cross/native file; meson auto-detects the host gcc/clang + the
# system LLVM-15/libclc/SPIRV-Tools (all installed in the image). Only the tools are needed, but
# building the nouveau driver natively is what produces the nouveau precomp compiler.
rm -rf "$NB"
meson setup "$NB" \
  --buildtype=plain --prefix="$PREFIX" \
  -Dvulkan-drivers=nouveau -Dgallium-drivers='' \
  -Dopengl=false -Dgles1=disabled -Dgles2=disabled -Degl=disabled -Dglx=disabled \
  -Dplatforms='' -Dvideo-codecs='' -Dllvm=enabled \
  -Dshared-glapi=disabled -Dgbm=disabled \
  -Dmesa-clc=enabled -Dprecomp-compiler=enabled \
  -Dinstall-mesa-clc=true -Dinstall-precomp-compiler=true \
  -Dstatic-libclc=all \
  "$@"

# Build tools. Full `ninja` may fail linking the native NVK ICD (.so) on Switch diagnostic
# externs (g_drm_shim_log_sink) — that ICD is unused; we need mesa_clc + vtn_bindgen.
ninja -C "$NB" src/compiler/clc/mesa_clc src/compiler/spirv/vtn_bindgen || ninja -C "$NB" || true
if [ ! -x "$NB/src/compiler/clc/mesa_clc" ] || [ ! -x "$NB/src/compiler/spirv/vtn_bindgen" ]; then
  echo "ERROR: mesa_clc / vtn_bindgen were not built"
  exit 1
fi
mkdir -p "$PREFIX/bin"
cp -f "$NB/src/compiler/clc/mesa_clc" "$PREFIX/bin/"
cp -f "$NB/src/compiler/spirv/vtn_bindgen" "$PREFIX/bin/"
# Optional: meson install for anything else marked install-mesa-clc (ignore ICD link errors).
ninja -C "$NB" install || true
echo "=== installed native tools ==="
ls -la "$PREFIX/bin/" | grep -iE 'clc|vtn|precomp|nak' || true
