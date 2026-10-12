# What's that?

It's Linux subsystem and proot builder.
Builds alpine-based subsystem with packages from `config.yaml` (and auto-updates) and also proot (based on versions specified in `proot/config.sh`). All the generated files are ready-to-paste into jniLibs in Android Studio app project.

## PRoot

`proot/build.sh` cross-compiles [termux/proot](https://github.com/termux/proot) with a statically linked talloc for `armeabi-v7a`, `arm64-v8a` and `x86_64`. The loaders (`libproot-loader.so`, `libproot-loader32.so`) are built from the same source, so they always match the proot binary.

Patches in `proot/patches/`:
- `proot-loader-path.patch` - loader names are configurable and a relative loader path is resolved next to the proot binary (the app's `nativeLibraryDir`)
- `proot-tmpdir.patch` - fall back to `$TMPDIR` when `PROOT_TMP_DIR` is unset
- `proot-ashmem-include-string.patch` - missing `<string.h>` include (same as Termux)

To update, bump `PROOT_REF` / `TALLOC_VERSION` in `proot/config.sh` (and `NDK_VERSION` in the workflow); a patch that no longer applies fails the build.

## Releases

Releases are in the releases tab, with tags `YY.MM.DD`, and for proot binaries `proot-*`.
