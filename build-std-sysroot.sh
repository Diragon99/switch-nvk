#!/usr/bin/env bash
# Build a prebuilt Rust std SYSROOT for aarch64-switch-horizon so meson-invoked `rustc`
# (which can't use cargo's -Zbuild-std) finds std. Run in switch-nvk-build with /work=D:\switch-nvk.
set -e
export RUST_TARGET_PATH=/work RUSTC_BOOTSTRAP=1
export RUSTFLAGS='-Zunstable-options -L /opt/devkitpro/devkitA64/aarch64-none-elf/lib -L /opt/devkitpro/libnx/lib'
TGT=aarch64-switch-horizon
SYSROOT=/work/sysroot
RUSTC_SYSROOT="$(rustc --print sysroot)"

# 1. build-std (release) on a lib crate -> produces std + deps rlibs.
# crates.io libc rejects aarch64-switch-horizon; -Zbuild-std ignores [patch], so we
# overwrite the fetched registry source with our patched libc-switch (0.2.191 + aarch64 types).
# IMPORTANT: do NOT rsync --delete (wipes .cargo-ok → cargo re-extracts stock tarball).
rm -rf /tmp/stdsr && mkdir -p /tmp/stdsr/src && cd /tmp/stdsr
printf '#![no_main]\n' > src/lib.rs
cat > Cargo.toml <<'EOF'
[package]
name = "stdsr"
version = "0.0.0"
edition = "2021"
[lib]
crate-type = ["rlib"]
[profile.release]
panic = "abort"
EOF

# Fetch/extract libc-0.2.191 into the registry (compile may fail — ignore).
cargo +nightly fetch -Zbuild-std=core,alloc,std,panic_abort --target "$TGT" || true
cargo +nightly build --release -Zbuild-std=core,alloc,std,panic_abort --target "$TGT" >/tmp/stdsr-first.log 2>&1 || true

LIBC_SRC="$(find "${CARGO_HOME:-$HOME/.cargo}/registry/src" -maxdepth 2 -type d -name 'libc-0.2.191' | head -1)"
if [ -z "$LIBC_SRC" ]; then
  echo "ERROR: libc-0.2.191 not found in cargo registry after fetch"
  exit 1
fi
echo "=== overlaying patched libc onto $LIBC_SRC ==="
rsync -a \
  --exclude .git \
  --exclude target \
  --exclude Cargo.lock \
  --exclude .cargo-ok \
  /work/libc-switch/ "$LIBC_SRC/"
sed -i 's/\r$//' "$LIBC_SRC/src/unix/newlib/mod.rs"
if ! grep -q 'target_os = "horizon", target_arch = "aarch64"' "$LIBC_SRC/src/unix/newlib/mod.rs"; then
  echo "ERROR: aarch64-horizon off_t patch missing after overlay"
  exit 1
fi
echo "=== patch verified in registry libc ==="
touch "$LIBC_SRC/.cargo-ok"

cargo +nightly build --release -Zbuild-std=core,alloc,std,panic_abort --target "$TGT"

# 2. Assemble sysroot. Recent cargo puts build-std rlibs under release/build/<crate>/<hash>/out/
# (not release/deps/).
mkdir -p "$SYSROOT/lib/rustlib/$TGT/lib"
FOUND=0
while IFS= read -r f; do
  cp -f "$f" "$SYSROOT/lib/rustlib/$TGT/lib/"
  FOUND=$((FOUND + 1))
done < <(find "/tmp/stdsr/target/$TGT/release" -type f \( -name '*.rlib' -o -name '*.rmeta' \))
# Also pick up legacy deps/ layout if present.
if [ -d "/tmp/stdsr/target/$TGT/release/deps" ]; then
  cp -f "/tmp/stdsr/target/$TGT/release/deps"/*.rlib "$SYSROOT/lib/rustlib/$TGT/lib/" 2>/dev/null || true
  cp -f "/tmp/stdsr/target/$TGT/release/deps"/*.rmeta "$SYSROOT/lib/rustlib/$TGT/lib/" 2>/dev/null || true
fi
echo "=== copied $FOUND rlib/rmeta into sysroot ==="
ls "$SYSROOT/lib/rustlib/$TGT/lib/" | grep -E 'libstd|libcore|liballoc' | head
if ! ls "$SYSROOT/lib/rustlib/$TGT/lib/"libstd*.rlib >/dev/null 2>&1; then
  echo "ERROR: libstd*.rlib missing from sysroot"
  exit 1
fi

# rustc also needs the host toolchain bits: symlink host sysroot for everything else
for d in "$RUSTC_SYSROOT/lib/rustlib"/*; do
  b=$(basename "$d");
  [ "$b" = "$TGT" ] && continue
  [ -e "$SYSROOT/lib/rustlib/$b" ] || ln -s "$d" "$SYSROOT/lib/rustlib/$b" 2>/dev/null || true
done
ln -sf "$RUSTC_SYSROOT/lib/rustlib/src" "$SYSROOT/lib/rustlib/src" 2>/dev/null || true

# 3. Validate: rustc finds std via --sysroot (rlib emit — no -lc/-lm link).
cd /tmp && printf 'pub fn n() -> usize { vec![1,2,3].len() }\n' > t.rs
echo "=== plain rustc --sysroot test (no build-std) ==="
if ! rustc -Zunstable-options --target "$TGT" --sysroot "$SYSROOT" -C panic=abort \
    --crate-type=rlib t.rs -o /tmp/libt.rlib 2>/tmp/sysroot-test.err; then
  tail -15 /tmp/sysroot-test.err
  echo "SYSROOT TEST: FAIL"
  exit 1
fi
echo "SYSROOT TEST: OK (rustc finds std via prebuilt sysroot)"
