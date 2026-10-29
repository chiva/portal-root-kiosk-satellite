# check=skip=FromPlatformFlagConstDisallowed

# Meta Portal Provisioner for Kiosk Satellite
#
# Self-contained Linux x86_64 image carrying the full Android build toolchain
# (JDK, SDK Platform, Build Tools, NDK) plus this repository, so a single
# `docker run` drives tools/provision_portal.py against a Portal reachable over
# wireless ADB. The toolchain versions mirror the constants in
# tools/provision_portal.py and android-env.mk; override them with build args if
# the repository bumps them.
#
# The container talks to the Portal over TCP (`--serial <ip>:5555`), so run it
# with `--network host` and do the one-time USB bootstrap from the host.

# Pinned to linux/amd64: the Android NDK ships only an x86_64 host toolchain
# (prebuilt/linux-x86_64), which the component Makefiles reference directly, so
# an arm64 image would download a clang it cannot execute. It is native on an
# x86_64 host and runs under emulation on an arm64 host.
FROM --platform=linux/amd64 debian:bookworm-slim

# Pinned to the versions the provisioner validates. Keep in sync with
# ANDROID_NDK_VERSION / ANDROID_BUILD_TOOLS_VERSION / ANDROID_PLATFORM_VERSION
# in tools/provision_portal.py and android-env.mk.
ARG ANDROID_PLATFORM_VERSION=android-36
ARG ANDROID_BUILD_TOOLS_VERSION=37.0.0
ARG ANDROID_NDK_VERSION=28.2.13676358
ARG ANDROID_CMDLINE_TOOLS_VERSION=13114758

ENV DEBIAN_FRONTEND=noninteractive \
    ANDROID_SDK_ROOT=/opt/android-sdk

# Host build commands the provisioner checks for: make, javac, jar, keytool
# (JDK), git, python3, plus curl/unzip to fetch the SDK and ca-certificates for
# TLS. adb is installed from the Android platform-tools below so its version
# matches the toolchain.
RUN apt-get update \
    && apt-get install --no-install-recommends --yes \
        ca-certificates \
        curl \
        git \
        make \
        openjdk-17-jdk-headless \
        python3 \
        unzip \
    && rm -rf /var/lib/apt/lists/*

# Install the Android SDK command-line tools, then the exact platform, build
# tools, platform-tools (adb) and NDK the provisioner expects.
RUN set -eux; \
    mkdir -p "${ANDROID_SDK_ROOT}/cmdline-tools"; \
    curl -fsSL -o /tmp/cmdline-tools.zip \
        "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_CMDLINE_TOOLS_VERSION}_latest.zip"; \
    unzip -q /tmp/cmdline-tools.zip -d "${ANDROID_SDK_ROOT}/cmdline-tools"; \
    mv "${ANDROID_SDK_ROOT}/cmdline-tools/cmdline-tools" "${ANDROID_SDK_ROOT}/cmdline-tools/latest"; \
    rm /tmp/cmdline-tools.zip; \
    yes | "${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin/sdkmanager" --licenses >/dev/null; \
    "${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin/sdkmanager" \
        "platform-tools" \
        "platforms;${ANDROID_PLATFORM_VERSION}" \
        "build-tools;${ANDROID_BUILD_TOOLS_VERSION}" \
        "ndk;${ANDROID_NDK_VERSION}" >/dev/null; \
    NDK_DIR="${ANDROID_SDK_ROOT}/ndk/${ANDROID_NDK_VERSION}"; \
    SYSROOT_LIB="${NDK_DIR}/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib"; \
    rm -rf "${ANDROID_SDK_ROOT}/cmdline-tools"; \
    rm -rf "${NDK_DIR}/sources" "${NDK_DIR}/shader-tools"; \
    rm -rf "${SYSROOT_LIB}/riscv64-linux-android" \
           "${SYSROOT_LIB}/x86_64-linux-android" \
           "${SYSROOT_LIB}/i686-linux-android"

# Resolve the toolchain paths the provisioner and Makefiles read. These mirror
# the defaults in android_build_environment() so the build runs with no extra
# configuration.
ENV NDK="${ANDROID_SDK_ROOT}/ndk/${ANDROID_NDK_VERSION}" \
    ANDROID_NDK_HOME="${ANDROID_SDK_ROOT}/ndk/${ANDROID_NDK_VERSION}" \
    BUILD_TOOLS="${ANDROID_SDK_ROOT}/build-tools/${ANDROID_BUILD_TOOLS_VERSION}" \
    ANDROID_JAR="${ANDROID_SDK_ROOT}/platforms/${ANDROID_PLATFORM_VERSION}/android.jar" \
    D8="${ANDROID_SDK_ROOT}/build-tools/${ANDROID_BUILD_TOOLS_VERSION}/d8"
ENV PATH="${ANDROID_SDK_ROOT}/platform-tools:${ANDROID_SDK_ROOT}/build-tools/${ANDROID_BUILD_TOOLS_VERSION}:${PATH}"

# Run as an unprivileged user; nothing here needs root. The debug keystore and
# the adb authorization keys live under this user's HOME. The SDK is left
# root-owned and world-readable (how sdkmanager installs it); chowning it would
# duplicate the whole ~2.8 GB toolchain into a second layer, so builder only
# reads it.
RUN groupadd --gid 1000 builder \
    && useradd --uid 1000 --gid 1000 --create-home --home-dir /home/builder builder \
    && mkdir -p /opt/portal /home/builder/.android \
    && chown -R builder:builder /opt/portal /home/builder

# Bake the repository in so the image is self-contained and rebuilt on each push.
COPY --chown=builder:builder . /opt/portal

USER builder
WORKDIR /opt/portal
ENV HOME=/home/builder

# Persist the adb keys and the generated debug keystore across runs when a
# volume is mounted here, so the Portal stays authorized between invocations.
VOLUME ["/home/builder/.android"]

# `docker run <image> --serial <ip>:5555 --profile kiosk ...` appends straight
# onto the provisioner. `docker run <image> --help` prints its usage.
ENTRYPOINT ["python3", "/opt/portal/tools/provision_portal.py"]
CMD ["--help"]
