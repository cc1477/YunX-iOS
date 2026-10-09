#!/bin/sh
set -eu

# Only arm64 device and Apple Silicon simulator targets exist in Stage 1.
case "${PLATFORM_NAME:-}" in
    iphoneos|iphonesimulator) ;;
    *) echo "error: Unsupported platform: ${PLATFORM_NAME:-unset}" >&2; exit 1 ;;
esac
case " ${ARCHS:-} " in
    *" x86_64 "*) echo "error: Use an arm64 iOS simulator (Apple Silicon Mac)." >&2; exit 1 ;;
esac

if [ -z "${JAVA_HOME:-}" ]; then
    JAVA_HOME=$(/usr/libexec/java_home -v 17)
    export JAVA_HOME
fi

cd "$SRCROOT/.."
./gradlew ":shared:link${KOTLIN_FRAMEWORK_BUILD_TYPE}Framework${KOTLIN_TARGET}"
