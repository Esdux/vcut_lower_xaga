#!/usr/bin/env bash
# 构建 vcutlower 控制 APK（Kotlin + Jetpack Compose + AGP）
#
# 用法：bash tools/build_apk.sh [--no-copy] [gradle 附加参数...]
#
# 依赖的环境变量（都有默认值，换机器时覆盖即可）：
#   JAVA_HOME      JDK 21
#   ANDROID_HOME   Android SDK（build-tools 35.0.0 + platform android-35 及以上）
#   GRADLE_BIN     gradle 可执行文件；默认用仓库自带 gradlew
#   GRADLE_USER_HOME  Gradle 缓存目录（默认 ~/.gradle）
#
# 签名：仓库不含密钥。把 keystore.properties（storeFile/storePassword/keyAlias/keyPassword）
# 放到 app/ 下即用该密钥签名；没有这个文件时自动回退 debug 密钥（能装，但升级身份不同）。
set -euo pipefail

NO_COPY=0
GRADLE_ARGS=()
for a in "$@"; do
  case "$a" in
    --no-copy) NO_COPY=1 ;;
    *) GRADLE_ARGS+=("$a") ;;
  esac
done

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
APP_SRC="$REPO/app"
MODULE_DIR="$REPO/module"

[ -d "$APP_SRC" ] || { echo "ERROR: 找不到源码 $APP_SRC"; exit 1; }

if [ -n "${GRADLE_BIN:-}" ]; then
  GRADLE="$GRADLE_BIN"
elif [ -x "$APP_SRC/gradlew" ]; then
  GRADLE="$APP_SRC/gradlew"
else
  GRADLE=$(command -v gradle || true)
fi
[ -n "$GRADLE" ] && [ -x "$GRADLE" ] || { echo "ERROR: 找不到 gradle（设 GRADLE_BIN 或放 gradlew）"; exit 1; }

[ -n "${JAVA_HOME:-}" ] || echo "WARN: JAVA_HOME 未设置，需 JDK 21"
[ -n "${ANDROID_HOME:-}" ] || echo "WARN: ANDROID_HOME 未设置"
export PATH="${JAVA_HOME:+$JAVA_HOME/bin:}$PATH"

echo "- JAVA_HOME   ${JAVA_HOME:-<未设>}"
echo "- ANDROID_HOME ${ANDROID_HOME:-<未设>}"
echo "- GRADLE_USER_HOME ${GRADLE_USER_HOME:-~/.gradle}"
echo "- gradle      $GRADLE"

cd "$APP_SRC"
"$GRADLE" :app:assembleRelease --no-daemon ${GRADLE_ARGS[@]+"${GRADLE_ARGS[@]}"}

APK="$APP_SRC/app/build/outputs/apk/release/app-release.apk"
[ -f "$APK" ] || { echo "ERROR: 构建结束但产物不存在: $APK"; exit 1; }
echo "- 产物 $APK"

if [ "$NO_COPY" -eq 0 ] && [ -d "$MODULE_DIR" ]; then
  cp "$APK" "$MODULE_DIR/vcutlower.apk"
  echo "- 已同步到模块目录 $MODULE_DIR/vcutlower.apk"
fi

sha256sum "$APK"
