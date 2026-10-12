#!/bin/bash

# --- Sources ---
# Talloc Version
export TALLOC_VERSION="2.5.0"

# Proot: Can be a tag, a branch name (master) or a specific Commit Hash.
# The loaders are built from the same source, so they always match.
export PROOT_REPO="termux/proot"
export PROOT_REF="v5.1.107.96"

# --- Android Configuration ---
export ANDROID_API_LEVEL="29" # Android 10
# Architectures to build
export TARGET_ARCHS="arm arm64 x86 x86_64"

# --- Directories ---
export BUILD_DIR="${PWD}/build"
export SRC_DIR="${PWD}/src"
export OUT_DIR="${PWD}/out"
export PATCH_DIR="${PWD}/patches"
