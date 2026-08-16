#!/usr/bin/env bash
set -euo pipefail
ARCH="${1:?arch required}"
case "$ARCH" in
  armv7l) ABI=armeabi-v7a;; arm64) ABI=arm64-v8a;; x86) ABI=x86;; x86_64) ABI=x86_64;; *) exit 2;;
esac
ROOT="${RUNNER_TEMP:-/tmp}/mpv-lite-$ARCH"
OUT="${GITHUB_WORKSPACE:-$PWD}/out"
rm -rf "$ROOT"; mkdir -p "$ROOT" "$OUT/jniLibs/$ABI"
git clone --filter=blob:none https://github.com/mpv-android/mpv-android.git "$ROOT/mpv-android"
git -C "$ROOT/mpv-android" checkout --detach ad98fc9
BS="$ROOT/mpv-android/buildscripts"
cd "$BS"
IN_CI=1 ./download.sh
for spec in 'dav1d 54706fc' 'ffmpeg d32b387' 'libass 3087d2b' 'libplacebo 4d82c68' 'mpv f4d13e1'; do set -- $spec; git -C "$BS/deps/$1" checkout --detach "$2"; done
git -C "$BS/deps/libplacebo" submodule update --init --recursive
python3 - "$BS" <<'PY'
from pathlib import Path
import sys
bs=Path(sys.argv[1])
dec=[
'h264','hevc','vp8','vp9','libdav1d','mpeg1video','mpeg2video','mpeg4','msmpeg4v2','msmpeg4v3','h263','h263p','flv','theora','vc1','wmv1','wmv2','wmv3','prores','prores_raw','mjpeg','mjpegb','png','webp','gif','bmp','rawvideo','ffv1','huffyuv','rv30','rv40',
'h264_mediacodec','hevc_mediacodec','vp8_mediacodec','vp9_mediacodec','av1_mediacodec','mpeg2_mediacodec','mpeg4_mediacodec',
'aac','aac_fixed','aac_latm','mp3','mp3float','mp3adu','mp3adufloat','mp3on4','mp3on4float','opus','vorbis','flac','alac','ac3','eac3','truehd','mlp','dca','ape','wavpack','tta','amrnb','amrwb','cook',
'pcm_s8','pcm_u8','pcm_s16le','pcm_s16be','pcm_s24le','pcm_s24be','pcm_s32le','pcm_s32be','pcm_f32le','pcm_f32be','pcm_f64le','pcm_f64be','pcm_alaw','pcm_mulaw','pcm_bluray','pcm_dvd',
'ass','ssa','subrip','webvtt','mov_text','text','hdmv_pgs_subtitle','dvdsub','dvbsub','xsub','eia_608','wrapped_avframe']
flt=['buffer','buffersink','abuffer','abuffersink','null','anull','scale','format','crop','pad','transpose','rotate','fps','framerate','setpts','trim','yadif','bwdif','hwdownload','hwupload','hwmap','colorspace','tonemap','aformat','aresample','volume','pan','atempo','equalizer','acompressor','alimiter','channelmap','channelsplit','asetpts','atrim']
def arr(xs): return '\n'.join(f'    "{x}"' for x in xs)
p=bs/'include/depinfo.sh'; t=p.read_text().replace('dep_mpv=(ffmpeg libass lua libplacebo curl)','dep_mpv=(ffmpeg libass libplacebo curl)'); p.write_text(t)
p=bs/'scripts/mpv.sh'; t=p.read_text()
if '-D{lua,libcurl}=enabled' not in t: raise SystemExit('mpv option layout changed')
t=t.replace('-D{lua,libcurl}=enabled','-Dlua=disabled -Dlibcurl=enabled')
if '-Dmanpage-build=disabled' not in t: raise SystemExit('mpv manpage layout changed')
t=t.replace('-Dmanpage-build=disabled','-Dcplugins=disabled -Dlibavdevice=disabled -Dbuild-date=false -Dmanpage-build=disabled'); p.write_text(t)
p=bs/'buildall.sh'; t=p.read_text(); old='export LDFLAGS="-Wl,-O1,--icf=safe -Wl,-z,max-page-size=16384"'; new='export LDFLAGS="-Wl,-O1,--icf=safe,--gc-sections -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384"'
if old not in t: raise SystemExit('LDFLAGS layout changed')
p.write_text(t.replace(old,new))
ff=f'''#!/bin/bash -e
. ../../include/path.sh
if [ "$1" = build ]; then true; elif [ "$1" = clean ]; then rm -rf _build$ndk_suffix; exit 0; else exit 255; fi
mkdir -p _build$ndk_suffix; cd _build$ndk_suffix
cpu=armv7-a
[[ "$ndk_triple" == aarch64* ]] && cpu=armv8-a
[[ "$ndk_triple" == x86_64* ]] && cpu=generic
[[ "$ndk_triple" == i686* ]] && cpu="i686 --disable-asm"
cpuflags=; [[ "$ndk_triple" == arm* ]] && cpuflags="$cpuflags -mfpu=neon -mcpu=cortex-a8"
wanted_decoders=(
{arr(dec)}
)
wanted_filters=(
{arr(flt)}
)
keep() {{ local kind="$1"; shift; local avail kept=() x; avail="$(../configure --list-${{kind}})"; for x in "$@"; do grep -qx "$x" <<<"$avail" && kept+=("$x") || true; done; local IFS=,; echo "${{kept[*]}}"; }}
decoder_csv="$(keep decoders "${{wanted_decoders[@]}}")"; filter_csv="$(keep filters "${{wanted_filters[@]}}")"
args=(--target-os=android --enable-cross-compile --cross-prefix=$ndk_triple- --cc=$CC --pkg-config=pkg-config --nm=llvm-nm --arch=${{ndk_triple%%-*}} --cpu=$cpu --extra-cflags="-I$prefix_dir/include $cpuflags -ffunction-sections -fdata-sections" --extra-ldflags="-L$prefix_dir/lib -Wl,--gc-sections -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384" --enable-jni --enable-mediacodec --enable-mbedtls --enable-libdav1d --enable-libxml2 --disable-vulkan --disable-static --enable-shared --enable-gpl --enable-version3 --enable-small --disable-stripping --disable-doc --disable-programs --disable-devices --disable-decoders --enable-decoder="$decoder_csv" --disable-filters --enable-filter="$filter_csv" --disable-encoders --disable-muxers --enable-encoder=mjpeg,png --enable-muxer=mov,matroska,mpegts)
../configure "${{args[@]}}"; make -j${{cores:-2}}; make DESTDIR="$prefix_dir" install
'''
p=bs/'scripts/ffmpeg.sh'; p.write_text(ff); p.chmod(0o755)
PY
cd "$BS"
./buildall.sh --arch "$ARCH" mpv
P="$BS/prefix/$ARCH"; D="$OUT/jniLibs/$ABI"; cp -L "$P"/lib/*.so "$D"/
NDK="$BS/sdk/android-ndk-r29"; HOST="$(find "$NDK/toolchains/llvm/prebuilt" -mindepth 1 -maxdepth 1 -type d | head -1)"; RE="$HOST/bin/llvm-readelf"; OD="$HOST/bin/llvm-objdump"; ST="$HOST/bin/llvm-strip"
if for s in "$D"/*.so; do "$RE" -d "$s"; done | grep -q libc++_shared.so; then case "$ABI" in armeabi-v7a) T=arm-linux-androideabi;; arm64-v8a) T=aarch64-linux-android;; x86) T=i686-linux-android;; x86_64) T=x86_64-linux-android;; esac; cp "$HOST/sysroot/usr/lib/$T/libc++_shared.so" "$D/"; fi
for s in "$D"/*.so; do "$ST" --strip-unneeded "$s"; done
R="$OUT/16kb-$ABI.txt"; :>"$R"
for s in "$D"/*.so; do echo "### $(basename "$s")" >>"$R"; "$OD" -p "$s" | awk '/^[[:space:]]*LOAD /{print}' >>"$R"; "$OD" -p "$s" | awk '/^[[:space:]]*LOAD /{if(match($0,/align 2\*\*([0-9]+)/,a)&&a[1]<14)bad=1}END{exit bad?1:0}' || { echo "16KB FAIL $s"; exit 1; }; done
if [ "$ARCH" = arm64 ]; then mkdir -p "$OUT/include"; cp -R "$P/include/mpv" "$OUT/include/"; fi
du -h "$D"/* | sort -h
