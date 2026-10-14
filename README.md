# What's that?

It's Linux subsystem and proot builder.
Builds a Termux-based subsystem with packages from `config.yaml` (and auto-updates) and also proot (based on versions specified in `proot/config.sh`). All the generated files are ready-to-paste into jniLibs in Android Studio app project.

Both are built for every ABI Google Play supports: `armeabi-v7a`, `arm64-v8a`, `x86` and `x86_64`.

## Rootfs

`.github/workflows/build-rootfs.yml` runs once a month (1st) and on demand. A release is only published when a package changed, with a changelog of the differences per part.

The rootfs comes in parts (`config.yaml`): the base (`librootfs.tar.xz.so`), which the app unpacks when it first starts, and an extension per feature (`libfeature-<name>-rootfs.tar.xz.so`, e.g. `media` for yt-dlp and FFmpeg), which it unpacks on the feature's first use and deletes with its data. An extension holds its packages with their dependencies, minus what the parts it builds on have (`requires`, and always the base); what two extensions both need goes to the one they both build on (`rootfs/parts.py`). The base's `etc/extensions.json` tells the app what each extension requires, its size and what it holds; each extension lists its files in `etc/extensions/<name>.files`.

The rootfs is built from [Termux packages](https://github.com/termux/termux-packages) inside [termux-docker](https://github.com/termux/termux-docker) (`rootfs/build.sh`, with FFmpeg in `rootfs/ffmpeg.sh`): the packages from `config.yaml` are installed, pip packages are installed (and built, with `build_packages`), and only the files of those packages, their dependencies and what pip added are exported - not the rest of the Termux bootstrap. Files the app's features don't need at runtime (docs, headers, tests, dev tools, unused Perl and Python modules) are pruned as well (`PRUNE_PATTERNS` in `rootfs/build.sh`). FFmpeg (for yt-dlp) is built from source (`rootfs/ffmpeg.sh`) instead of installed: Termux's package pulls in ~390 MB of libraries, this one has FFmpeg's own codecs plus LAME and Opus. Its version and checksum follow Termux's recipe, so it updates with it. The Termux prefix is in `usr/` of the archive; the app binds it to `/data/data/com.termux/files/usr` (where Termux binaries expect it) inside proot. Package maintainer scripts are not run.

Termux binaries use Android's own libc (bionic) and are linked for 16 KB pages, so they run on Android 15+ devices and Android 17 emulators with 16 KB pages. The workflow checks every ELF of the 64-bit rootfs for that.

## PRoot

`proot/build.sh` cross-compiles [termux/proot](https://github.com/termux/proot) with a statically linked talloc. The loaders (`libproot-loader.so`, `libproot-loader32.so` on 64-bit ABIs) are built from the same source, so they always match the proot binary. The workflow runs on every push to `proot/`.

Patches in `proot/patches/`:
- `proot-loader-path.patch` - loader names are configurable and a relative loader path is resolved next to the proot binary (the app's `nativeLibraryDir`)
- `proot-tmpdir.patch` - fall back to `$TMPDIR` when `PROOT_TMP_DIR` is unset
- `proot-ashmem-include-string.patch` - missing `<string.h>` include (same as Termux)
- `proot-loader-16k-pages.patch` - loaders are linked for 16 KB pages too (they don't get `LDFLAGS`; the NDK only defaults to it for 64-bit ABIs)

To update, bump `PROOT_REF` / `TALLOC_VERSION` in `proot/config.sh` (and `NDK_VERSION` in the workflow); a patch that no longer applies fails the build.

## Releases

Releases are in the releases tab, with tags `YY.MM.DD`, and for proot binaries `proot-*`.
