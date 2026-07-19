#!/usr/bin/env bash
# ============================================================================
# OrzAudioKit WASM Build Script
# ============================================================================
# Builds libopenmpt and other audio libraries to WebAssembly for browser-side
# chiptune playback without server CPU usage.
#
# Prerequisites:
#   - Emscripten SDK (emsdk) installed and activated
#   - cmake, make, pkg-config
#
# Usage:
#   ./script/build-wasm.sh                    # Build all
#   ./script/build-wasm.sh --only-openmpt     # Build only libopenmpt
#   ./script/build-wasm.sh --clean            # Clean build artifacts
#
# Output:
#   Resources/Public/audio/orz_audio.wasm      # WASM binary
#   Resources/Public/audio/orz_audio.js        # JS glue code
# ============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="${ORZ_WASM_OUTPUT_DIR:-$PROJECT_DIR/Resources/Public/audio}"
BUILD_DIR="$PROJECT_DIR/.wasm-build"
CACHE_DIR="$BUILD_DIR/cache"

LIBOPENMPT_VERSION="0.8.0"
LIBOPENMPT_URL="https://lib.openmpt.org/files/libopenmpt/src/libopenmpt-${LIBOPENMPT_VERSION}+release.autotools.tar.gz"

# Game Music Emu — 用于 NSF/SPC 格式
GME_VERSION="0.6.3"
GME_URL="https://github.com/libgme/game-music-emu/archive/refs/tags/${GME_VERSION}.tar.gz"

# libsidplayfp — 用于 SID (Commodore 64) 格式
SIDPLAYFP_VERSION="3.0.2"
SIDPLAYFP_URL="https://github.com/libsidplayfp/libsidplayfp/releases/download/v${SIDPLAYFP_VERSION}/libsidplayfp-${SIDPLAYFP_VERSION}.tar.gz"

# mpg123 — 用于 MO3 中 MP3 压缩采样的解码
MPG123_VERSION="1.32.6"
MPG123_URL="https://www.mpg123.de/download/mpg123-${MPG123_VERSION}.tar.bz2"

# libogg / libvorbis — 用于 MO3 中 Ogg Vorbis 压缩采样的解码
OGG_VERSION="1.3.5"
OGG_URL="https://downloads.xiph.org/releases/ogg/libogg-${OGG_VERSION}.tar.gz"
VORBIS_VERSION="1.3.7"
VORBIS_URL="https://downloads.xiph.org/releases/vorbis/libvorbis-${VORBIS_VERSION}.tar.gz"

# uade (deprecated) — 旧版 UAE Amiga 模拟器，已替换为 ahx2play

JOBS=${JOBS:-$(sysctl -n hw.logicalcpu 2>/dev/null || nproc 2>/dev/null || echo 4)}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log()  { echo -e "${GREEN}[WASM]${NC} $1" >&2; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
err()  { echo -e "${RED}[ERR]${NC} $1" >&2; exit 1; }

# ------------------------------------------------------------------
# Parse arguments
# ------------------------------------------------------------------
ONLY_OPENMPT=false
CLEAN=false
for arg in "$@"; do
    case "$arg" in
        --only-openmpt) ONLY_OPENMPT=true ;;
        --clean) CLEAN=true ;;
        *) warn "Unknown argument: $arg" ;;
    esac
done

# ------------------------------------------------------------------
# Clean
# ------------------------------------------------------------------
if $CLEAN; then
    log "Cleaning build directory (keeping cache)..."
    # 保留 cache/ 避免重复下载，只删除编译产物
    for item in "$BUILD_DIR"/*; do
        [ "$item" = "$CACHE_DIR" ] && continue
        rm -rf "$item"
    done
    log "Done."
    exit 0
fi

# ------------------------------------------------------------------
# Check prerequisites
# ------------------------------------------------------------------
check_prereqs() {
    if ! command -v emcmake &>/dev/null; then
        err "Emscripten SDK not found. Install it first:
  git clone https://github.com/emscripten-core/emsdk.git
  cd emsdk
  ./emsdk install latest
  ./emsdk activate latest
  source ./emsdk_env.sh"
    fi

    if ! command -v cmake &>/dev/null; then
        err "cmake is required. Install with: brew install cmake"
    fi

    if ! command -v gzip &>/dev/null && ! command -v tar &>/dev/null; then
        err "tar and gzip are required."
    fi

    log "Emscripten: $(emcc --version | head -1)"
    log "cmake:      $(cmake --version | head -1)"
}

# ------------------------------------------------------------------
# Download source
# ------------------------------------------------------------------
download_source() {
    local url="$1"
    local name="$2"
    local dest="$CACHE_DIR/${name}.tar.gz"
    local src_dir="$BUILD_DIR/src/${name}"

    if [ -d "$src_dir" ]; then
        log "Source $name already downloaded, skipping."
        echo "$src_dir"
        return
    fi

    mkdir -p "$(dirname "$dest")" "$src_dir"

    if [ ! -f "$dest" ]; then
        log "Downloading $name..."
        curl -fsSL "$url" -o "$dest" || err "Failed to download $name"
    fi

    log "Extracting $name..."
    tar xzf "$dest" -C "$src_dir" --strip-components=1 2>/dev/null || \
        tar xzf "$dest" -C "$src_dir" 2>/dev/null || \
        err "Failed to extract $name"

    echo "$src_dir"
}

# ------------------------------------------------------------------
# Build libopenmpt (module player: .xm, .mod, .it, .s3m, etc.)
# ------------------------------------------------------------------
build_libopenmpt() {
    local mpg123_prefix="$1"
    local ogg_prefix="$2"
    local vorbis_prefix="$3"
    log "Building libopenmpt ${LIBOPENMPT_VERSION}..."

    local src_dir
    src_dir=$(download_source "$LIBOPENMPT_URL" "libopenmpt" 2>/dev/null || echo "")

    if [ -z "$src_dir" ] || [ ! -f "$src_dir/configure" ]; then
        warn "libopenmpt source not available at $src_dir, trying alternate..."
        # Try to download again via a different method
        src_dir="$BUILD_DIR/src/libopenmpt"
        if [ ! -f "$src_dir/configure" ]; then
            warn "Cannot build libopenmpt - source unavailable"
            echo ""
            return
        fi
    fi

    local build_dir="$BUILD_DIR/libopenmpt"
    mkdir -p "$build_dir"

    pushd "$build_dir" >/dev/null || err "Cannot enter build dir"

    # Configure with Emscripten (autotools, not CMake)
    local mpg123_flag="--without-mpg123"
    if [ -n "$mpg123_prefix" ] && [ -f "$mpg123_prefix/lib/libmpg123.a" ]; then
        mpg123_flag="--with-mpg123=$mpg123_prefix"
        log "mpg123 enabled: $mpg123_prefix"
    fi

    local ogg_flag="--without-ogg"
    local vorbis_flag="--without-vorbis"
    local vorbisfile_flag="--without-vorbisfile"
    if [ -n "$ogg_prefix" ] && [ -f "$ogg_prefix/lib/libogg.a" ]; then
        ogg_flag="--with-ogg=$ogg_prefix"
        log "ogg enabled: $ogg_prefix"
    fi
    if [ -n "$vorbis_prefix" ] && [ -f "$vorbis_prefix/lib/libvorbis.a" ]; then
        vorbis_flag="--with-vorbis=$vorbis_prefix"
        log "vorbis enabled: $vorbis_prefix"
    fi
    if [ -n "$vorbis_prefix" ] && [ -f "$vorbis_prefix/lib/libvorbisfile.a" ]; then
        vorbisfile_flag="--with-vorbisfile=$vorbis_prefix"
    fi

    log "Configuring libopenmpt with Emscripten..."

    # 设置 PKG_CONFIG_PATH 让 configure 能找到 mpg123/ogg/vorbis
    local pkg_config_path=""
    [ -d "$BUILD_DIR/mpg123/install/lib/pkgconfig" ] && \
        pkg_config_path="$BUILD_DIR/mpg123/install/lib/pkgconfig"
    [ -d "$BUILD_DIR/ogg/install/lib/pkgconfig" ] && \
        pkg_config_path="${pkg_config_path:+$pkg_config_path:}$BUILD_DIR/ogg/install/lib/pkgconfig"
    [ -d "$BUILD_DIR/vorbis/install/lib/pkgconfig" ] && \
        pkg_config_path="${pkg_config_path:+$pkg_config_path:}$BUILD_DIR/vorbis/install/lib/pkgconfig"

    # emconfigure 会清理 PKG_CONFIG_PATH，直接手动设置编译环境
    local pkg_conf_path=""
    for dir in "$BUILD_DIR/mpg123/install" "$BUILD_DIR/ogg/install" "$BUILD_DIR/vorbis/install"; do
        if [ -d "$dir/lib/pkgconfig" ]; then
            pkg_conf_path="${pkg_conf_path:+$pkg_conf_path:}$dir/lib/pkgconfig"
        fi
    done

    CC=emcc CXX=em++ AR=emar RANLIB=emranlib NM=emnm PKG_CONFIG_PATH="$pkg_conf_path" \
    "$src_dir/configure" \
        --host=wasm32-unknown-emscripten \
        --disable-shared \
        --enable-static \
        --disable-examples \
        --disable-tests \
        --disable-openmpt123 \
        $mpg123_flag \
        $ogg_flag \
        $vorbis_flag \
        $vorbisfile_flag \
        --without-portaudio \
        --without-sdl2 \
        --without-flac \
        --without-zlib \
        CC=emcc CXX=em++ AR=emar RANLIB=emranlib NM=emnm \
        --prefix="$build_dir/install" >&2 || {
            warn "libopenmpt configure failed"
            popd >/dev/null
            echo ""
            return
        }

    log "Building libopenmpt..."
    emmake make -j"$JOBS" >&2 || {
        warn "libopenmpt make failed"
        popd >/dev/null
        echo ""
        return
    }

    popd >/dev/null
    echo "$build_dir"
}

# ------------------------------------------------------------------
# Build Game Music Emu (NSF, SPC)
# ------------------------------------------------------------------
build_libgme() {
    log "Building Game Music Emu ${GME_VERSION}..."

    local src_dir
    src_dir=$(download_source "$GME_URL" "game-music-emu" 2>/dev/null || echo "")

    if [ -z "$src_dir" ] || [ ! -f "$src_dir/CMakeLists.txt" ]; then
        warn "gme source not available"
        echo ""
        return
    fi

    local build_dir="$BUILD_DIR/gme"
    mkdir -p "$build_dir"
    pushd "$build_dir" >/dev/null || { warn "Cannot enter gme build dir"; echo ""; return; }

    log "Configuring game-music-emu with Emscripten..."
    emcmake cmake "$src_dir" \
        -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_BUILD_TYPE=MinSizeRel \
        -DENABLE_UBSAN=OFF \
        -DGME_ENABLE_SPC=ON \
        -DGME_ENABLE_NSF=ON \
        -DGME_ENABLE_GBS=OFF \
        -DGME_ENABLE_GYM=OFF \
        -DGME_ENABLE_HES=OFF \
        -Wno-dev >&2 || {
            warn "gme cmake failed"
            popd >/dev/null
            echo ""
            return
        }

    log "Building game-music-emu..."
    emmake make -j"$JOBS" >&2 || {
        warn "gme make failed"
        popd >/dev/null
        echo ""
        return
    }

    popd >/dev/null

    # 返回 gme 库和头文件路径
    local lib_path=$(find "$build_dir" -name "libgme.a" 2>/dev/null | head -1)
    if [ -z "$lib_path" ]; then
        warn "libgme.a not found in $build_dir"
        echo ""
        return
    fi

    # 找到头文件目录 — gme.h 在 gme/gme.h，需父目录
    local inc_path=$(find "$src_dir" -name "gme.h" -exec dirname {} \; 2>/dev/null | head -1)
    if [ -n "$inc_path" ]; then
        inc_path="$(dirname "$inc_path")"  # 升到包含 gme/ 子目录的目录
    else
        inc_path="$build_dir"
    fi

    echo "$lib_path|$inc_path"
}

# ------------------------------------------------------------------
# Build libsc68 (Atari ST YM / Amiga formats: sc68, ym)
# ------------------------------------------------------------------
build_libsc68() {
    log "Building libsc68 (photonstorm fork)..."

    local src_dir="$BUILD_DIR/src/sc68"
    if [ ! -d "$src_dir" ] || [ ! -f "$src_dir/api68/api68.h" ]; then
        warn "sc68 source not available at $src_dir"
        echo ""
        return
    fi

    local build_dir="$BUILD_DIR/sc68"
    mkdir -p "$build_dir"
    pushd "$build_dir" >/dev/null || { warn "Cannot enter build dir"; echo ""; return; }

    # 收集所有 .c 源文件（排除 emscripten 目录下的 adapter.c）
    local C_FILES=()
    for d in api68 emu68 file68 io68 unice68 sc68; do
        for f in "$src_dir/$d"/*.c; do
            [ -f "$f" ] && C_FILES+=("$f")
        done
    done
    # 排除 io68/paula*.c，避免与 ahx2play 的 paula.o 冲突
    if [ ${#C_FILES[@]} -eq 0 ]; then
        warn "No sc68 source files found"
        popd >/dev/null
        echo ""
        return
    fi

    local inc_flags="-I$src_dir -I$src_dir/emscripten -I$src_dir/file68 -I$src_dir/api68"
    log "Compiling ${#C_FILES[@]} sc68 source files..."
    local compiled=0
    for cfile in "${C_FILES[@]}"; do
        local basename="${cfile##*/}"
        local dirpart="${cfile%/*}"
        local subdir="${dirpart##*/}"
        # 用子目录名作前缀避免同名文件冲突（如 emu68/error68.c → emu68_error68.o）
        local objname="${subdir}_${basename%.c}.o"
        emcc -c "$cfile" \
            -o "$objname" \
            $inc_flags \
            -Wno-pointer-sign \
            -Wno-incompatible-function-pointer-types \
            -O3 \
            -D paula=sc68_paula \
            -D paulav=sc68_paulav \
            -D EMSCRIPTEN \
            -D 'EMSCRIPTEN_KEEPALIVE=__attribute__((used))' \
            -s WASM=1 2>/dev/null || {
                warn "Failed to compile $cfile"
                continue
            }
        compiled=$((compiled + 1))
    done

    # 打包为静态库
    local objs=( *.o )
    if [ ${#objs[@]} -gt 0 ]; then
        emar cr libsc68.a "${objs[@]}"
        emranlib libsc68.a
        log "sc68 library created: libsc68.a (${#objs[@]} objects)"
    else
        warn "No object files produced"
        popd >/dev/null
        echo ""
        return
    fi

    popd >/dev/null
    echo "$build_dir/libsc68.a|$src_dir"
}

# ------------------------------------------------------------------
# Build libbinio (binary I/O library, needed by AdPlug)
# ------------------------------------------------------------------
build_libbinio() {
    log "Building libbinio..."
    local src_dir="$BUILD_DIR/src/libbinio/src"
    if [ ! -d "$src_dir" ]; then
        warn "libbinio source not available"
        echo ""
        return
    fi

    local build_dir="$BUILD_DIR/binio"
    mkdir -p "$build_dir"
    pushd "$build_dir" >/dev/null || return

    local C_FILES=()
    for f in "$src_dir"/*.cpp; do
        [ -f "$f" ] && C_FILES+=("$f")
    done

    if [ ${#C_FILES[@]} -eq 0 ]; then
        warn "No libbinio source files found"
        popd >/dev/null
        echo ""
        return
    fi

    local inc_flags="-I$BUILD_DIR/src/libbinio/include -I$BUILD_DIR/src/libbinio/src -Dstricmp=strcasecmp -Wno-register"
    for cfile in "${C_FILES[@]}"; do
        local basename="${cfile##*/}"
        emcc -c "$cfile" -o "${basename%.cpp}.o" $inc_flags -O2 2>/dev/null || continue
    done

    local objs=( *.o )
    if [ ${#objs[@]} -gt 0 ]; then
        emar cr libbinio.a "${objs[@]}"
        emranlib libbinio.a
        log "libbinio library created: libbinio.a (${#objs[@]} objects)"
    fi

    popd >/dev/null
    echo "$build_dir/libbinio.a"
}

# ------------------------------------------------------------------
# Build AdPlug (AdLib OPL2/3 emulator: rad, d00, hsc, amd)
# ------------------------------------------------------------------
build_adplug() {
    log "Building AdPlug..."
    local src_dir="$BUILD_DIR/src/adplug/src"
    if [ ! -d "$src_dir" ]; then
        warn "AdPlug source not available"
        echo ""
        return
    fi

    # 先确保 libbinio 已构建
    local binio_a="$BUILD_DIR/binio/libbinio.a"
    if [ ! -f "$binio_a" ]; then
        build_libbinio >/dev/null 2>&1 || { warn "libbinio build failed"; echo ""; return; }
        binio_a="$BUILD_DIR/binio/libbinio.a"
    fi

    local build_dir="$BUILD_DIR/adplug"
    mkdir -p "$build_dir"
    pushd "$build_dir" >/dev/null || return

    local C_FILES=()
    for f in "$src_dir"/*.cpp "$src_dir"/*.c; do
        [ -f "$f" ] && C_FILES+=("$f")
    done

    if [ ${#C_FILES[@]} -eq 0 ]; then
        warn "No AdPlug source files found"
        popd >/dev/null
        echo ""
        return
    fi

    local inc_flags="-I$BUILD_DIR/src/adplug/src -I$BUILD_DIR/src/libbinio/src -I$BUILD_DIR/src/libbinio/include -Dstricmp=strcasecmp -Wno-register"
    for cfile in "${C_FILES[@]}"; do
        local basename="${cfile##*/}"
        local ext="${cfile##*.}"
        if [ "$ext" = "c" ]; then
            emcc -c "$cfile" -o "${basename%.c}.o" $inc_flags -O2 2>/dev/null || continue
        else
            emcc -c "$cfile" -o "${basename%.cpp}.o" $inc_flags -O2 2>/dev/null || continue
        fi
    done

    local objs=( *.o )
    if [ ${#objs[@]} -gt 0 ]; then
        emar cr libadplug.a "${objs[@]}"
        emranlib libadplug.a
        # 把 libbinio.a 也放到同目录，方便链接时找到
        cp "$binio_a" "$build_dir/"
        log "AdPlug library created: libadplug.a (${#objs[@]} objects)"
    fi

    popd >/dev/null
    echo "$build_dir/libadplug.a|$build_dir"
}

# ------------------------------------------------------------------
# Build libsidplayfp (SID format)
# ------------------------------------------------------------------
build_libsidplayfp() {
    log "Building libsidplayfp ${SIDPLAYFP_VERSION}..."

    local src_dir
    src_dir=$(download_source "$SIDPLAYFP_URL" "libsidplayfp" 2>/dev/null || echo "")

    if [ -z "$src_dir" ] || [ ! -f "$src_dir/configure" ]; then
        warn "libsidplayfp source not available"
        echo ""
        return
    fi

    local build_dir="$BUILD_DIR/sidplayfp"
    mkdir -p "$build_dir"

    log "Configuring libsidplayfp with Emscripten..."
    pushd "$build_dir" >/dev/null || { warn "Cannot enter build dir"; echo ""; return; }

    emconfigure "$src_dir/configure" \
        --host=wasm32-unknown-emscripten \
        --disable-shared \
        --enable-static \
        --disable-silent-rules \
        CC=emcc CXX=em++ \
        --prefix="$build_dir/install" >&2 || {
            warn "libsidplayfp configure failed"
            popd >/dev/null
            echo ""
            return
        }

    log "Building libsidplayfp..."
    emmake make -j"$JOBS" >&2 || {
        warn "libsidplayfp make failed"
        popd >/dev/null
        echo ""
        return
    }

    popd >/dev/null

    # 查找 lib .a 文件
    local lib_path=$(find "$build_dir" -name "libsidplayfp.a" 2>/dev/null | head -1)
    if [ -z "$lib_path" ]; then
        warn "libsidplayfp.a not found"
        echo ""
        return
    fi

    # 查找 include 目录 — sidplayfp.h 在 sidplayfp/ 子目录中
    local inc_h_path=$(find "$src_dir" -name "sidplayfp.h" -exec dirname {} \; 2>/dev/null | head -1)
    if [ -n "$inc_h_path" ]; then
        inc_path="$(dirname "$inc_h_path")"  # 升一级到包含 sidplayfp/ 的目录
    fi

    # The generated sidversion.h lives under the build tree, while the public
    # headers remain in the source tree. Preserve both include roots.
    # The sidlite builder headers also ship with the fetched source.
    echo "$lib_path|$inc_path|$build_dir/src|$src_dir/src/builders/sidlite-builder"
}

# ------------------------------------------------------------------
# Build mpg123 (MO3 MP3-compressed sample decoder)
# ------------------------------------------------------------------
build_mpg123() {
    log "Building mpg123 ${MPG123_VERSION}..."

    local src_dir
    src_dir=$(download_source "$MPG123_URL" "mpg123" 2>/dev/null || echo "")

    if [ -z "$src_dir" ] || [ ! -f "$src_dir/configure" ]; then
        warn "mpg123 source not available"
        echo ""
        return
    fi

    local build_dir="$BUILD_DIR/mpg123"
    local prefix="$build_dir/install"
    mkdir -p "$build_dir"

    pushd "$build_dir" >/dev/null || err "Cannot enter build dir"

    emconfigure "$src_dir/configure" \
        --host=wasm32-unknown-emscripten \
        --disable-shared \
        --enable-static \
        --enable-libmpg123 \
        --disable-programs \
        --disable-examples \
        --disable-modules \
        --with-cpu=generic \
        --enable-int-quality=no \
        --prefix="$prefix" 2>&1 | tail -5 >&2

    log "Building mpg123..."
    emmake make -j"$JOBS" install 2>&1 | tail -5 >&2

    local lib="$prefix/lib/libmpg123.a"
    if [ -f "$lib" ]; then
        log "mpg123 built: $(wc -c < "$lib") bytes"
        echo "$prefix"
    else
        warn "mpg123 build failed, MO3 compressed samples may not load"
        echo ""
    fi

    popd >/dev/null || true
}

# ------------------------------------------------------------------
# Build libogg (Ogg container, required by libvorbis)
# ------------------------------------------------------------------
build_ogg() {
    log "Building libogg ${OGG_VERSION}..."

    local src_dir
    src_dir=$(download_source "$OGG_URL" "ogg" 2>/dev/null || echo "")

    if [ -z "$src_dir" ] || [ ! -f "$src_dir/configure" ]; then
        warn "libogg source not available"
        echo ""
        return
    fi

    local build_dir="$BUILD_DIR/ogg"
    local prefix="$build_dir/install"
    mkdir -p "$build_dir"

    pushd "$build_dir" >/dev/null || err "Cannot enter build dir"

    # 旧版 config.sub 不认识 emscripten host triple，用更通用的
    local host_triple="wasm32"
    if grep -q "emscripten" "$src_dir/config.sub" 2>/dev/null; then
        host_triple="wasm32-unknown-emscripten"
    fi

    emconfigure "$src_dir/configure" \
        --host="$host_triple" \
        --disable-shared --enable-static \
        --prefix="$prefix" 2>&1 | tail -5 >&2

    emmake make -j"$JOBS" install 2>&1 | tail -5 >&2

    local lib="$prefix/lib/libogg.a"
    if [ -f "$lib" ]; then
        log "libogg built: $(wc -c < "$lib") bytes"
        echo "$prefix"
    else
        warn "libogg build failed"
        echo ""
    fi

    popd >/dev/null || true
}

# ------------------------------------------------------------------
# Build libvorbis (Vorbis audio codec, for MO3 compressed samples)
# ------------------------------------------------------------------
build_vorbis() {
    local ogg_prefix="$1"
    log "Building libvorbis ${VORBIS_VERSION}..."

    local src_dir
    src_dir=$(download_source "$VORBIS_URL" "vorbis" 2>/dev/null || echo "")

    if [ -z "$src_dir" ] || [ ! -f "$src_dir/configure" ]; then
        warn "libvorbis source not available"
        echo ""
        return
    fi

    local build_dir="$BUILD_DIR/vorbis"
    local prefix="$build_dir/install"
    mkdir -p "$build_dir"

    pushd "$build_dir" >/dev/null || err "Cannot enter build dir"

    local host_triple="wasm32"
    if grep -q "emscripten" "$src_dir/config.sub" 2>/dev/null; then
        host_triple="wasm32-unknown-emscripten"
    fi

    PKG_CONFIG_PATH="$ogg_prefix/lib/pkgconfig" \
    emconfigure "$src_dir/configure" \
        --host="$host_triple" \
        --disable-shared --enable-static \
        --with-ogg="$ogg_prefix" \
        --prefix="$prefix" 2>&1 | tail -5 >&2

    emmake make -j"$JOBS" install 2>&1 | tail -5 >&2

    local lib="$prefix/lib/libvorbis.a"
    local libfile="$prefix/lib/libvorbisfile.a"
    if [ -f "$lib" ] && [ -f "$libfile" ]; then
        log "libvorbis built: $(wc -c < "$lib") + $(wc -c < "$libfile") bytes"
        echo "$prefix"
    else
        warn "libvorbis build failed"
        echo ""
    fi

    popd >/dev/null || true
}

# ------------------------------------------------------------------
# Setup uade source (不活跃 — 已替换为 ahx2play，保留供参考）
# ------------------------------------------------------------------
setup_uade_source() {
    local src_dir
    src_dir=$(download_source "$UADE_URL" "uade-${UADE_VERSION}" 2>/dev/null || echo "")

    if [ -z "$src_dir" ] || [ ! -d "$src_dir" ]; then
        warn "uade source not available"
        return 1
    fi

    local uade_dst="$BUILD_DIR/src/uade"
    if [ -f "$uade_dst/newcpu.c" ]; then
        log "uade source already set up at $uade_dst"
        return 0
    fi

    log "Setting up uade source from $src_dir..."
    mkdir -p "$uade_dst"

    # uade 3.x 源文件在 src/ 子目录下
    local uade_src="$src_dir/src"
    if [ ! -d "$uade_src" ]; then
        warn "uade source src/ directory not found"
        return 1
    fi

    # 复制 UAE 核心源文件
    for f in newcpu.c memory.c custom.c cia.c audio.c missing.c \
             readcpu.c sinctable.c sd-sound-generic.c; do
        cp "$uade_src/$f" "$uade_dst/" 2>/dev/null || true
    done
    # machdep/support.c
    mkdir -p "$uade_dst/machdep"
    cp "$uade_src/machdep/support.c" "$uade_dst/machdep/" 2>/dev/null || true

    # ── 生成 CPU 表文件 ──
    # 编译 build68k（主机编译器，非 emscripten）
    local build68k_bin="$BUILD_DIR/build68k"
    if [ ! -f "$build68k_bin" ]; then
        log "Compiling build68k generator (host compiler)..."
        local b68k_inc="-I$uade_src -I$uade_src/include"
        gcc -o "$build68k_bin" "$uade_src/build68k.c" $b68k_inc -lm 2>&1 || \
            clang -o "$build68k_bin" "$uade_src/build68k.c" $b68k_inc -lm 2>&1 || \
            warn "Cannot compile build68k, CPU table files may be missing"
    fi

    if [ -x "$build68k_bin" ]; then
        log "Generating CPU table files..."
        # build68k 输出 cpustbl.c cpudefs.c cpuemu.c 到当前目录
        (cd "$uade_dst" && "$build68k_bin" 2>/dev/null) || warn "build68k generation failed"
    fi

    # 复制 uade 头文件
    local inc_src="$uade_src/include"
    if [ -d "$inc_src" ]; then
        mkdir -p "$uade_dst/include"
        cp -r "$inc_src"/* "$uade_dst/include/" 2>/dev/null || true
    fi
    # 复制 frontends/include
    local frontend_inc=$(find "$src_dir" -type d -name "include" -path "*/frontends/include" 2>/dev/null | head -1)
    if [ -n "$frontend_inc" ]; then
        mkdir -p "$uade_dst/frontends"
        cp -r "$frontend_inc" "$uade_dst/frontends/" 2>/dev/null || true
    fi
    # 复制 frontends/common
    local common_src=$(find "$src_dir" -type d -name "common" -path "*/frontends/common" 2>/dev/null | head -1)
    if [ -n "$common_src" ]; then
        mkdir -p "$uade_dst/frontends"
        cp -r "$common_src" "$uade_dst/frontends/" 2>/dev/null || true
    fi

    # 生成 sysconfig.h（如果不存在）
    if [ ! -f "$uade_dst/sysconfig.h" ]; then
        cat > "$uade_dst/sysconfig.h" << 'SYSCONFIG'
#ifndef SYSCONFIG_H
#define SYSCONFIG_H
#define HAVE_STDLIB_H 1
#define HAVE_STRING_H 1
#define HAVE_MEMSET 1
#define WORDS_BIGENDIAN 0
#endif
SYSCONFIG
    fi

    # 检查关键文件
    if [ -f "$uade_dst/newcpu.c" ]; then
        local c_count=$(find "$uade_dst" -maxdepth 1 -name '*.c' | wc -l)
        log "uade source ready: $c_count source files"
        find "$uade_dst" -maxdepth 1 -name '*.c' -o -name '*.h' | sort | while read -r f; do
            log "  $(basename "$f")"
        done
        return 0
    else
        warn "uade source setup failed - newcpu.c not found"
        return 1
    fi
}

# ------------------------------------------------------------------
# Generate WASM wrapper
# ------------------------------------------------------------------
generate_wrapper() {
    local libopenmpt_dir="$1"
    local gme_result="$2"  # "lib_path|inc_path" or empty
    local sidplayfp_result="$3"  # "lib_path|inc_path" or empty

    # Parse gme result
    local gme_lib=""
    local gme_inc=""
    if [ -n "$gme_result" ]; then
        gme_lib="${gme_result%%|*}"
        gme_inc="${gme_result#*|}"
    fi

    # 构建源文件和库列表
    local source_files=()
    local libs=()
    local inc_dirs=()

    # C 源文件路径（OrzAudioKitCXX — 统一 C 解码层，与 SPM 共享）
    local ORZ_SRC="$PROJECT_DIR/Sources/OrzAudioKitCXX"
    source_files=(
        "$ORZ_SRC/dispatch/orz_dispatch.c"
        "$ORZ_SRC/dispatch/audio_engine.c"
        "$ORZ_SRC/helpers/cxx_helpers.cpp"
        "$ORZ_SRC/openmpt/openmpt_impl.c"
        "$ORZ_SRC/gme/gme_impl.c"
        "$ORZ_SRC/ym6/ym6_impl.c"
        "$ORZ_SRC/bp/bp_impl.c"
        "$ORZ_SRC/ym6/unlzh_ym.c"
        "$ORZ_SRC/ym6/lhasa_adapter.c"
        "$ORZ_SRC/ym6/lhasa/lh5_decoder.c"
        "$ORZ_SRC/stub_decoders.c"
        "$ORZ_SRC/midi/midi_impl.c"
    )


    # ── 条件编译其他解码器（仅在其依赖库可用时加入）──

    # ASAP (sap) — 直接编译 asap.c（预生成 C 源码，无需 .a）
    if [ -f "$BUILD_DIR/src/asap/asap.c" ]; then
        source_files+=("$ORZ_SRC/asap/asap_impl.c" "$BUILD_DIR/src/asap/asap.c")



    fi

    # adplug (rad, d00, hsc, amd) — 需要 libadplug + libbinio
    if [ -d "$BUILD_DIR/src/adplug/src" ] && [ -f "$BUILD_DIR/adplug/libadplug.a" ]; then
        source_files+=("$ORZ_SRC/adplug/adplug_impl.c" "$ORZ_SRC/adplug/adplug_wrap.cpp")
    fi

    # sc68 (sc68, ym) — 需要 sc68 源码
    if [ -d "$BUILD_DIR/src/sc68" ] && [ -f "$BUILD_DIR/src/sc68/api68/api68.h" ]; then
        source_files+=("$ORZ_SRC/sc68/sc68_impl.c")
    fi

    # v2m-player (V2M format) — 使用统一实现（与 SPM 共享）
    if [ -d "$BUILD_DIR/src/v2m" ]; then
        source_files+=("$ORZ_SRC/v2m/v2m_native_impl.cpp")
        local v2m_src_src="$BUILD_DIR/src/v2m/src"
        for f in v2mplayer.cpp v2mconv.cpp sounddef.cpp ronan.cpp synth_core.cpp; do
            [ -f "$v2m_src_src/$f" ] && source_files+=("$v2m_src_src/$f")
        done
    fi

    # ahx2play (AHX format) — 轻量解码器，替换完整 UAE 仿真器
    if [ -d "$BUILD_DIR/src/ahx2play" ]; then
        patch -N -d "$BUILD_DIR/src/ahx2play" -p1 < "$ORZ_SRC/uade/ahx2play-reset.patch" >/dev/null 2>&1 || true
        patch -N -d "$BUILD_DIR/src/ahx2play" -p1 < "$ORZ_SRC/uade/ahx2play-context.patch" >/dev/null 2>&1 || true
        source_files+=("$ORZ_SRC/uade/uade_native_ahx.c")
        source_files+=(
            "$BUILD_DIR/src/ahx2play/loader.c"
            "$BUILD_DIR/src/ahx2play/replayer.c"
            "$BUILD_DIR/src/ahx2play/paula.c"
        )
        inc_dirs+=("$BUILD_DIR/src/ahx2play")
    else
        log "ahx2play not available, AHX format disabled"
    fi
    inc_dirs+=("$ORZ_SRC/include")
    inc_dirs+=("$BUILD_DIR/src/asap")  # ASAP 头文件 (asap.h)
    # libopenmpt 头文件（0.8.0 头文件在 libopenmpt/libopenmpt.h）
    if [ -d "$BUILD_DIR/src/libopenmpt/libopenmpt" ]; then
        inc_dirs+=("$BUILD_DIR/src/libopenmpt")
    fi
    # v2m-player 头文件
    # adplug 头文件
    # libbinio 头文件
    if [ -d "$BUILD_DIR/src/libbinio/include" ]; then
        inc_dirs+=("$BUILD_DIR/src/libbinio/include")
    fi
    if [ -d "$BUILD_DIR/src/libbinio/src" ]; then
        inc_dirs+=("$BUILD_DIR/src/libbinio/src")
    fi
    if [ -d "$BUILD_DIR/src/adplug/src" ]; then
        inc_dirs+=("$BUILD_DIR/src/adplug/src")
    fi
    if [ -d "$BUILD_DIR/src/v2m/src" ]; then
        inc_dirs+=("$BUILD_DIR/src/v2m/src")   # v2mplayer.h, types.h, synth.h
    fi
    # sc68 头文件
    if [ -d "$BUILD_DIR/src/sc68" ]; then
        inc_dirs+=("$BUILD_DIR/src/sc68")           # api68/api68.h
        inc_dirs+=("$BUILD_DIR/src/sc68/api68")     # api68.h (fallback)
        inc_dirs+=("$BUILD_DIR/src/sc68/file68")    # file68/*.h
        inc_dirs+=("$BUILD_DIR/src/sc68")           # config68.h etc
    fi

    # libopenmpt
    if [ -n "$libopenmpt_dir" ]; then
        local libopenmpt_wasm=""
        for try_path in \
            "$libopenmpt_dir/libopenmpt.a" \
            "$libopenmpt_dir/.libs/libopenmpt.a" \
            "$libopenmpt_dir/src/libopenmpt/.libs/libopenmpt.a" \
            "$libopenmpt_dir/install/lib/libopenmpt.a"; do
            if [ -f "$try_path" ]; then
                libopenmpt_wasm="$try_path"
                break
            fi
        done
        if [ -z "$libopenmpt_wasm" ]; then
            libopenmpt_wasm=$(find "$libopenmpt_dir" -name "libopenmpt.a" 2>/dev/null | head -1 || echo "")
        fi
        if [ -n "$libopenmpt_wasm" ]; then
            libs+=("$libopenmpt_wasm")
        fi

        local openmpt_inc=""
        for try_inc in \
            "$libopenmpt_dir/../include" \
            "$libopenmpt_dir/install/include" \
            "$BUILD_DIR/src/libopenmpt/libopenmpt"; do
            if [ -f "$try_inc/libopenmpt/libopenmpt.h" ]; then
                openmpt_inc="$try_inc"
                break
            elif [ -f "$try_inc/libopenmpt.h" ]; then
                openmpt_inc="$(dirname "$try_inc")"
                break
            fi
        done
        if [ -n "$openmpt_inc" ]; then
            inc_dirs+=("$openmpt_inc")
        fi
    fi

    # mpg123 (MO3 MP3 压缩采样解码)
    local mpg123_lib="$BUILD_DIR/mpg123/install/lib/libmpg123.a"
    if [ -f "$mpg123_lib" ]; then libs+=("$mpg123_lib"); fi

    # Ogg/Vorbis (MO3 压缩采样解码，通过 libopenmpt 调用)
    local ogg_lib="$BUILD_DIR/ogg/install/lib/libogg.a"
    local vorbis_lib="$BUILD_DIR/vorbis/install/lib/libvorbis.a"
    local vorbisfile_lib="$BUILD_DIR/vorbis/install/lib/libvorbisfile.a"
    if [ -f "$ogg_lib" ]; then libs+=("$ogg_lib"); fi
    if [ -f "$vorbisfile_lib" ]; then libs+=("$vorbisfile_lib"); fi
    if [ -f "$vorbis_lib" ]; then libs+=("$vorbis_lib"); fi

    # Game Music Emu
    if [ -n "$gme_lib" ]; then
        libs+=("$gme_lib")
        if [ -n "$gme_inc" ]; then
            inc_dirs+=("$gme_inc")
        fi
    fi

    # libsc68 (Atari ST YM / Amiga)
    # This library is small enough to rebuild, and its compile-time symbol
    # namespace is part of correctness. Reusing an archive built before those
    # flags changed silently brought back the no-op Paula path.
    local sc68_result
    sc68_result=$(build_libsc68)

    local sc68_lib=""
    local sc68_inc=""
    if [ -n "$sc68_result" ]; then
        sc68_lib="${sc68_result%%|*}"
        sc68_inc="${sc68_result#*|}"
        libs+=("$sc68_lib")
        if [ -n "$sc68_inc" ]; then
            inc_dirs+=("$sc68_inc")
            inc_dirs+=("$sc68_inc/api68")
            inc_dirs+=("$sc68_inc/file68")
            inc_dirs+=("$sc68_inc/emscripten")
        fi
    else
        warn "libsc68 build failed, sc68/ym formats will not be available"
    fi

    # ASAP (Atari POKEY) — 已作为源文件编译 in source_files

    # libsidplayfp (C++ wrapper)
    local sidplayfp_lib=""
    local sidplayfp_inc_raw=""
    if [ -n "$sidplayfp_result" ]; then
        sidplayfp_lib="${sidplayfp_result%%|*}"
        sidplayfp_inc_raw="${sidplayfp_result#*|}"
        source_files+=("$ORZ_SRC/sidplayfp/sidplayfp_impl.cpp")
        libs+=("$sidplayfp_lib")
        if [ -n "$sidplayfp_inc_raw" ]; then
            # 支持多个 include 路径 (用 | 分隔)
            IFS='|' read -ra inc_parts <<< "$sidplayfp_inc_raw"
            for part in "${inc_parts[@]}"; do
                if [ -n "$part" ] && [ -d "$part" ]; then
                    inc_dirs+=("$part")
                fi
            done
        fi
    fi

    # adplug (AdLib OPL2/3: rad, d00, hsc, amd)
    local adplug_lib="$BUILD_DIR/adplug/libadplug.a"
    local binio_lib="$BUILD_DIR/binio/libbinio.a"
    if [ ! -f "$adplug_lib" ]; then
        log "Building AdPlug for WASM..."
        local adplug_result=$(build_adplug)
        if [ -n "$adplug_result" ]; then
            adplug_lib="${adplug_result%%|*}"
            log "AdPlug built: $adplug_lib"
        fi
    fi
    if [ -f "$adplug_lib" ]; then
        libs+=("$adplug_lib")
        if [ -f "$binio_lib" ]; then
            libs+=("$binio_lib")
        fi
        log "AdPlug + libbinio linked"
    fi
    if [ ${#libs[@]} -eq 0 ]; then
        warn "No decoder libraries found, creating stub WASM binary."
        cat > "$BUILD_DIR/stub.c" << 'STUBC'
#include <emscripten.h>

EMSCRIPTEN_KEEPALIVE
int orz_audio_is_ready() { return 1; }

EMSCRIPTEN_KEEPALIVE
const char* orz_audio_version() { return "OrzAudioKit WASM v0.1.0 (stub)"; }
STUBC
        emcc "$BUILD_DIR/stub.c" \
            -O1 \
            -s WASM=1 \
            -s MODULARIZE=1 \
            -s EXPORT_NAME="OrzAudioKit" \
            -s EXPORTED_RUNTIME_METHODS='["ccall", "cwrap", "getValue", "setValue"]' \
            -s EXPORTED_FUNCTIONS='["_orz_audio_is_ready", "_orz_audio_version"]' \
            -s ALLOW_MEMORY_GROWTH=1 \
            -o "$OUTPUT_DIR/orz_audio.js"
        return
    fi

    # 构建包含标志
    local inc_flags=""
    for dir in "${inc_dirs[@]}"; do
        inc_flags="$inc_flags -I$dir"
    done

    log "Linking WASM with libraries: ${libs[*]}"

    emcc "${source_files[@]}" "${libs[@]}" \
        $inc_flags \
        -include "$PROJECT_DIR/Libraries/OrzAudioKit/thirdparty/ahx2play/mixer_stubs.h" \
        -D ORZ_HAVE_OPENMPT \
        -D ORZ_HAVE_GME \
        -s WASM=1 \
        -s MODULARIZE=1 \
        -s EXPORT_NAME="OrzAudioKit" \
        -s EXPORTED_RUNTIME_METHODS='["ccall", "cwrap", "getValue", "setValue", "UTF8ToString", "stringToUTF8", "lengthBytesUTF8", "HEAPU8", "HEAPU32", "HEAP32", "HEAPF32", "HEAPF64"]' \
        -s EXPORTED_FUNCTIONS='["_orz_load", "_orz_get_duration", "_orz_get_sample_rate", "_orz_get_channels", "_orz_render", "_orz_destroy", "_orz_decoder_create", "_orz_decoder_get_duration", "_orz_decoder_get_sample_rate", "_orz_decoder_get_channels", "_orz_decoder_render", "_orz_decoder_destroy", "_orz_decoder_get_subsong_count", "_orz_decoder_select_subsong", "_orz_decoder_seek_ms", "_orz_audio_can_decode", "_orz_abi_version", "_orz_build_info", "_orz_status_message", "_orz_get_format_count", "_orz_get_format_info", "_orz_probe", "_orz_decoder_create_memory", "_orz_decoder_get_stream_info", "_orz_decoder_render_f32", "_orz_decoder_seek", "_orz_decoder_select_subsong_v1", "_orz_decoder_reset", "_orz_decoder_cancel", "_orz_decoder_destroy_v1", "_malloc", "_free"]' \
        -s INITIAL_MEMORY=268435456 \
        -s ALLOW_MEMORY_GROWTH=0 \
        -s DISABLE_EXCEPTION_CATCHING=0 \
        -D __stdcall= \
        -D '__int64=long long' \
        --no-entry \
        -O3 \
        -o "$OUTPUT_DIR/orz_audio.js"

    log "WASM module created:"
    ls -lh "$OUTPUT_DIR/orz_audio.wasm" "$OUTPUT_DIR/orz_audio.js" 2>/dev/null || true
}

# Small dependency-free bundle for formats implemented entirely in this tree.
# The browser chooses this for BP/MIDI/YM and avoids downloading libopenmpt,
# GME, SID, AdPlug and SC68.
generate_builtin_wrapper() {
    local ORZ_SRC="$PROJECT_DIR/Sources/OrzAudioKitCXX"
    emcc \
        "$ORZ_SRC/dispatch/orz_dispatch.c" \
        "$ORZ_SRC/dispatch/audio_engine.c" \
        "$ORZ_SRC/ym6/ym6_impl.c" \
        "$ORZ_SRC/ym6/unlzh_ym.c" \
        "$ORZ_SRC/ym6/lhasa_adapter.c" \
        "$ORZ_SRC/ym6/lhasa/lh5_decoder.c" \
        "$ORZ_SRC/bp/bp_impl.c" \
        "$ORZ_SRC/midi/midi_impl.c" \
        "$ORZ_SRC/stub_decoders.c" \
        -I"$ORZ_SRC/include" \
        -s WASM=1 -s MODULARIZE=1 -s EXPORT_NAME="OrzAudioKit" \
        -s EXPORTED_RUNTIME_METHODS='["stringToUTF8", "lengthBytesUTF8", "HEAPU8", "HEAPU32", "HEAPF32", "HEAPF64"]' \
        -s EXPORTED_FUNCTIONS='["_orz_decoder_create", "_orz_decoder_get_duration", "_orz_decoder_get_sample_rate", "_orz_decoder_get_channels", "_orz_decoder_render", "_orz_decoder_destroy", "_orz_decoder_get_subsong_count", "_orz_decoder_select_subsong", "_orz_decoder_seek_ms", "_orz_audio_can_decode", "_orz_abi_version", "_orz_build_info", "_orz_status_message", "_orz_get_format_count", "_orz_get_format_info", "_orz_probe", "_orz_decoder_create_memory", "_orz_decoder_get_stream_info", "_orz_decoder_render_f32", "_orz_decoder_seek", "_orz_decoder_select_subsong_v1", "_orz_decoder_reset", "_orz_decoder_cancel", "_orz_decoder_destroy_v1", "_malloc", "_free"]' \
        -s INITIAL_MEMORY=33554432 -s ALLOW_MEMORY_GROWTH=1 \
        --no-entry -O3 -o "$OUTPUT_DIR/orz_audio_builtin.js"
    log "Built dependency-free WASM bundle:"
    ls -lh "$OUTPUT_DIR/orz_audio_builtin.wasm" "$OUTPUT_DIR/orz_audio_builtin.js"
}

# ------------------------------------------------------------------
# Main
# ------------------------------------------------------------------
main() {
    mkdir -p "$OUTPUT_DIR" "$BUILD_DIR" "$CACHE_DIR"

    check_prereqs

    # ── mpg123 (MO3 MP3 压缩采样解码) ──
    local mpg123_prefix=""
    local mpg123_lib=$(find "$BUILD_DIR/mpg123/install" -name "libmpg123.a" 2>/dev/null | head -1)
    if [ -n "$mpg123_lib" ]; then
        mpg123_prefix="$(dirname "$(dirname "$mpg123_lib")")"
        log "Using cached mpg123: $mpg123_lib"
    else
        log "mpg123 not cached, building from source..."
        mpg123_prefix=$(build_mpg123)
    fi

    # ── libogg (MO3 Ogg Vorbis 压缩采样解码) ──
    local ogg_prefix=""
    local ogg_lib=$(find "$BUILD_DIR/ogg/install" -name "libogg.a" 2>/dev/null | head -1)
    if [ -n "$ogg_lib" ]; then
        ogg_prefix="$(dirname "$(dirname "$ogg_lib")")"
        log "Using cached libogg: $ogg_lib"
    else
        log "libogg not cached, building from source..."
        ogg_prefix=$(build_ogg)
    fi

    # ── libvorbis (MO3 Ogg Vorbis 压缩采样解码) ──
    local vorbis_prefix=""
    local vorbis_lib=$(find "$BUILD_DIR/vorbis/install" -name "libvorbis.a" 2>/dev/null | head -1)
    if [ -n "$vorbis_lib" ]; then
        vorbis_prefix="$(dirname "$(dirname "$vorbis_lib")")"
        log "Using cached libvorbis: $vorbis_lib"
    else
        log "libvorbis not cached, building from source..."
        vorbis_prefix=$(build_vorbis "$ogg_prefix")
    fi

    # ── libopenmpt ──
    local libopenmpt_dir=""
    local libopenmpt_a=""
    local -a openmpt_candidates=(
        "$BUILD_DIR/libopenmpt/.libs/libopenmpt.a"
        "$BUILD_DIR/libopenmpt/libopenmpt.a"
        "$BUILD_DIR/libopenmpt/src/libopenmpt/.libs/libopenmpt.a"
    )
    for f in "${openmpt_candidates[@]}"; do
        if [ -f "$f" ]; then
            libopenmpt_a="$f"
            libopenmpt_dir="$(dirname "$f")"
            if [[ "$f" == *"/.libs/"* ]]; then
                libopenmpt_dir="$(dirname "$(dirname "$f")")"
            elif [[ "$f" == */install/lib/* ]]; then
                libopenmpt_dir="$(dirname "$(dirname "$(dirname "$f")")")"
            fi
            break
        fi
    done
    if [ -z "$libopenmpt_a" ]; then
        log "libopenmpt .a not cached, building from source..."
        libopenmpt_dir=$(build_libopenmpt "$mpg123_prefix" "$ogg_prefix" "$vorbis_prefix")
        if [ -z "$libopenmpt_dir" ] || [ ! -f "$libopenmpt_dir/.libs/libopenmpt.a" -a ! -f "$libopenmpt_dir/libopenmpt.a" ]; then
            warn "libopenmpt build failed, stub only"
            libopenmpt_dir=""
        fi
    else
        log "Using cached libopenmpt: $libopenmpt_a"
    fi

    # ── Game Music Emu ──
    local gme_result=""
    local gme_lib_path=$(find "$BUILD_DIR/gme" -name "libgme.a" 2>/dev/null | head -1)
    # gme 头文件以 #include <gme/gme.h> 引用 → -I 需指向含 gme/ 子目录的父目录
    local gme_inc_path=""
    # 从可能的源目录中查找正确的 include 父目录
    for d in "$BUILD_DIR/src/game-music-emu" "$BUILD_DIR/src/gme"; do
        if [ -f "$d/gme/gme.h" ]; then
            gme_inc_path="$d"
            break
        fi
    done
    if [ -n "$gme_lib_path" ]; then
        gme_result="${gme_lib_path}|${gme_inc_path}"
        log "Using cached game-music-emu: $gme_lib_path"
        log "  gme include path: $gme_inc_path"
    else
        gme_result=$(build_libgme)
    fi
    if [ -z "$gme_result" ]; then
        warn "game-music-emu build failed, NSF/SPC formats will not be available"
    fi

    # ── libsidplayfp ──
    local sidplayfp_result=""
    local sid_a=$(find "$BUILD_DIR/sidplayfp" -name "libsidplayfp.a" 2>/dev/null | head -1)
    local sid_inc_src=""
    local sid_h_path=$(find "$BUILD_DIR/src/libsidplayfp" -name "sidplayfp.h" 2>/dev/null | head -1)
    if [ -n "$sid_h_path" ]; then
        sid_inc_src="$(dirname "$(dirname "$sid_h_path")")"
    fi
    # 生成的头文件（如 sidversion.h）在 build 输出中
    local sid_inc_build="$BUILD_DIR/sidplayfp/src"
    # sidlite builder 头文件
    local sid_inc_sidlite="$BUILD_DIR/src/libsidplayfp/src/builders/sidlite-builder"
    # 合并多个 include 路径，用 | 分隔用于 generate_wrapper 解析
    local sid_inc=""
    for inc in "$sid_inc_src" "$sid_inc_build" "$sid_inc_sidlite"; do
        if [ -n "$inc" ] && [ -d "$inc" ]; then
            if [ -z "$sid_inc" ]; then
                sid_inc="$inc"
            else
                sid_inc="$sid_inc|$inc"
            fi
        fi
    done

    if [ -n "$sid_a" ]; then
        sidplayfp_result="${sid_a}|${sid_inc}"
        log "Using cached libsidplayfp: $sid_a"
    else
        sidplayfp_result=$(build_libsidplayfp)
    fi
    if [ -z "$sidplayfp_result" ]; then
        warn "libsidplayfp build failed, SID format will not be available"
    fi

    # ── ahx2play (AHX format, replaces full UAE emulator) ──
    if [ -d "$BUILD_DIR/src/ahx2play" ]; then
        # Fix paula.c for WASM: crtdbg.h is MSVC-only
        sed -i '' 's/#include <crtdbg.h>/#include <stdlib.h>/' "$BUILD_DIR/src/ahx2play/paula.c" 2>/dev/null || true
        log "ahx2play source present"
    else
        log "ahx2play not available, AHX format will be disabled"
    fi

    generate_wrapper "$libopenmpt_dir" "$gme_result" "$sidplayfp_result"
    generate_builtin_wrapper

    log "Build complete!"
    log "WASM output: $OUTPUT_DIR/orz_audio.wasm"
    log "JS glue:     $OUTPUT_DIR/orz_audio.js"
    log ""
    log "To use in the frontend, include in your HTML:"
    log '  <script src="/audio/orz_audio.js"></script>'
}

main "$@"
