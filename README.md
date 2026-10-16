# What's that?

It's Linux subsystem and proot builder.
Builds a Termux-based subsystem and proot, both set up in `config.yaml`: its `packages` section (the rootfs, auto-updated) and its `proot` section (proot's versions). All the generated files are ready-to-paste into jniLibs in Android Studio app project.

Both are built for every ABI Google Play supports: `armeabi-v7a`, `arm64-v8a`, `x86` and `x86_64` (`config.yaml`'s `abis`, with what each build calls them and the runner building them).

## Rootfs

`.github/workflows/build-rootfs.yml` runs once a month (1st) and on demand. A release is only published when a part changed, with the parts' versions and a changelog of the differences per part.

Each part has its own version (`rootfs/release.py`): a part keeps the previous release's archive, byte for byte, and its version as long as what goes into it is the same - its packages (its merged manifest), its `config.yaml` entry and script, and the settings and build scripts every part shares. It also keeps them when its files come out the same as there (their contents, links and modes, not their times; the base's own `etc/image-version` aside), e.g. after a build script changed in a way that didn't touch it. So the app (and Play, for an extension's module) only updates the parts that changed. The release's `parts.json` (also in `rootfs.tar.gz`, for the app) has each part's version and, per ABI, its size unpacked, its archive's size and what it holds.

The rootfs comes in parts (`config.yaml`): the base (`librootfs.tar.xz.so`), which the app unpacks when it first starts, and an extension per package (`libpackage-<name>.tar.xz.so`, e.g. `ytdlp`, which requires `python` and `ffmpeg`), which the app installs (as an on-demand Play module, with the tool's pages) and unpacks on a tool's first use, and deletes with its data. An extension holds its packages with their dependencies, minus what the parts it builds on have (`requires`, and always the base); what two extensions both need goes to the one they both build on (`rootfs/parts.py`). Each extension lists its files in `etc/extensions/<name>.files`, for the app to delete it again.

The rootfs is built from [Termux packages](https://github.com/termux/termux-packages) inside [termux-docker](https://github.com/termux/termux-docker) (`rootfs/build.sh`): the packages from `config.yaml` are installed, pip packages are installed (and built, with `build_packages`), and only the files of those packages, their dependencies and what pip added are exported - not the rest of the Termux bootstrap. Files the app's features don't need at runtime (docs, headers, tests, dev tools, unused Perl and Python modules) are pruned as well (`PRUNE_PATTERNS` in `rootfs/build.sh`). FFmpeg is Termux's package, with its video encoders (x264, x265, VP9, AV1) for the video encoder. A part can leave packages out (`exclude`, with what only they need, `rootfs/parts.py reachable`): FFmpeg leaves out Mesa's software Vulkan driver (with LLVM, most of its size), which is only loaded when a filter asks for Vulkan; libplacebo links Android's own `libvulkan.so`. yt-dlp is Termux's too (`yt-dlp`, provided by `python-yt-dlp`, as `pkg install yt-dlp` installs it; `build.sh` takes such a name as the package providing it). The Termux prefix is in `usr/` of the archive; the app binds it to `/data/data/com.termux/files/usr` (where Termux binaries expect it) inside proot. Package maintainer scripts are not run.

Termux binaries use Android's own libc (bionic) and are linked for 16 KB pages, so they run on Android 15+ devices and Android 17 emulators with 16 KB pages. The workflow checks every ELF of the 64-bit rootfs for that.

## PRoot

`proot/build.sh` cross-compiles [termux/proot](https://github.com/termux/proot) with a statically linked talloc. The loaders (`libproot-loader.so`, `libproot-loader32.so` on 64-bit ABIs) are built from the same source, so they always match the proot binary. The workflow runs on every push to `proot/`, and to `config.yaml` when its `proot` section or `abis` changed.

Patches in `proot/patches/`:
- `proot-loader-path.patch` - loader names are configurable and a relative loader path is resolved next to the proot binary (the app's `nativeLibraryDir`)
- `proot-tmpdir.patch` - fall back to `$TMPDIR` when `PROOT_TMP_DIR` is unset
- `proot-ashmem-include-string.patch` - missing `<string.h>` include (same as Termux)
- `proot-loader-16k-pages.patch` - loaders are linked for 16 KB pages too (they don't get `LDFLAGS`; the NDK only defaults to it for 64-bit ABIs)

To update, bump `ref` / `talloc` in `config.yaml`'s `proot` section (and `NDK_VERSION` in the workflow); a patch that no longer applies fails the build.

## Releases

Releases are in the releases tab, with tags `YY.MM.DD`, and for proot binaries `proot-*`. A rootfs part's version is the tag of the release it last changed in.
