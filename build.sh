#!/usr/bin/env bash
# =============================================================================
# Compila BlockLauncher (MCPELauncher) 0.8.1 + Render API en Ubuntu.
# Sigue los pasos del README del proyecto (ndk-build + ant), automatizados.
#
# Uso:   bash tools/build.sh
# Salida: out/BlockLauncher-0.8.1-renderapi-debug.apk
#
# Requisitos: Ubuntu 20.04/22.04 (x86_64) y JDK 8 (en GitHub Actions lo pone
# actions/setup-java). Variables opcionales al final de "Configuracion".
# =============================================================================
set -euo pipefail

# ----------------------------- Configuracion ---------------------------------
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:-$HOME/BLBUILD}"                 # carpeta de trabajo
SDK_DIR="$WORK/android-sdk"
NDK_DIR="$WORK/android-ndk-r10e"
OUT_DIR="$REPO_DIR/out"
OUT_APK="$OUT_DIR/BlockLauncher-0.8.1-renderapi-debug.apk"

TARGET="${ANDROID_TARGET:-android-19}"        # plataforma del SDK
BUILD_TOOLS="${BUILD_TOOLS:-25.0.3}"
SDK_TOOLS_URL="${SDK_TOOLS_URL:-https://dl.google.com/android/repository/tools_r25.2.5-linux.zip}"
NDK_URL="${NDK_URL:-https://dl.google.com/android/ndk/android-ndk-r10e-linux-x86_64.bin}"

# Dependencias (se pueden cambiar por variable de entorno)
APP_URL="${APP_URL:-https://github.com/zhuowei/MCPELauncher-app.git}"
AFILE_URL="${AFILE_URL:-https://github.com/zhuowei/aFileChooser.git}"
SUPERUSER_URL="${SUPERUSER_URL:-https://github.com/Chainfire/libsuperuser.git}"
# El codigo del zip es de abril-mayo de 2014: se fijan las dependencias a esa
# epoca. Con *_REF puedes forzar un commit/rama/tag concreto.
DEPS_BEFORE="${DEPS_BEFORE:-2014-05-05}"
APP_REF="${APP_REF:-}"
AFILE_REF="${AFILE_REF:-prefragments}"        # rama que usa el README
SUPERUSER_REF="${SUPERUSER_REF:-}"

# ------------------------------- Utilidades ----------------------------------
log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mAVISO: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

java_major() {
  java -version 2>&1 | awk -F '[".]' '/version/ { if ($2 == "1") print $3; else print $2; exit }'
}

# clone_dep URL DESTINO [REF] [FECHA]
#   Clona y deja el repo en REF; si no hay REF, en el ultimo commit anterior a FECHA.
clone_dep() {
  local url="$1" dest="$2" ref="${3:-}" before="${4:-}"
  [ -d "$dest/.git" ] || git clone -q --filter=blob:none "$url" "$dest"
  if [ -n "$ref" ] && git -C "$dest" rev-parse -q --verify "$ref^{commit}" >/dev/null 2>&1; then
    git -C "$dest" checkout -q "$ref"
  elif [ -n "$ref" ] && git -C "$dest" rev-parse -q --verify "origin/$ref^{commit}" >/dev/null 2>&1; then
    git -C "$dest" checkout -q "origin/$ref"
  else
    [ -z "$ref" ] || warn "No existe '$ref' en $url; uso la fecha $before."
    local c
    c="$(git -C "$dest" rev-list -1 --before="$before" HEAD 2>/dev/null || true)"
    [ -n "$c" ] || die "No encontre ningun commit anterior a $before en $url"
    git -C "$dest" checkout -q "$c"
  fi
  printf '   %s -> %s\n' "$(basename "$dest")" "$(git -C "$dest" rev-parse --short HEAD)"
}

# Asegura que una dependencia tenga forma de proyecto Ant "library".
ensure_lib_project() {
  local dir="$1" name="$2"
  [ -d "$dir" ] || die "Falta la carpeta $dir"
  if [ ! -f "$dir/project.properties" ] || ! grep -q '^android.library=true' "$dir/project.properties"; then
    warn "$name: anado project.properties (android.library=true)"
    printf 'target=%s\nandroid.library=true\n' "$TARGET" >> "$dir/project.properties"
  fi
  if [ ! -f "$dir/AndroidManifest.xml" ]; then
    warn "$name: anado AndroidManifest.xml minimo"
    cat > "$dir/AndroidManifest.xml" <<MANIFEST
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="$3">
    <uses-sdk android:minSdkVersion="9" />
</manifest>
MANIFEST
  fi
  # Si el repo ya usa el formato Gradle (src/main/java), le indicamos a Ant donde mirar.
  if [ -d "$dir/src/main/java" ]; then
    warn "$name: formato Gradle detectado, configuro source.dir para Ant"
    echo 'source.dir=src/main/java' >> "$dir/ant.properties"
    [ -d "$dir/src/main/res" ] && echo 'resource.dir=src/main/res' >> "$dir/ant.properties"
  fi
  return 0
}

# --------------------------------- Pasos -------------------------------------
check_java() {
  log "Comprobando JDK"
  [ -n "${JAVA_HOME:-}" ] && export PATH="$JAVA_HOME/bin:$PATH"
  command -v java >/dev/null || die "No hay Java en el PATH. Instala JDK 8."
  local v; v="$(java_major)"
  [ "$v" = "8" ] || die "Se necesita JDK 8 (las herramientas Ant de Android no funcionan con otras). Tienes Java $v."
}

install_packages() {
  [ "${SKIP_APT:-0}" = "1" ] && { log "SKIP_APT=1: omito apt"; return; }
  log "Instalando paquetes del sistema"
  local SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"
  $SUDO apt-get update -y
  $SUDO apt-get install -y --no-install-recommends ant git make p7zip-full unzip wget ca-certificates
  # Algunas herramientas antiguas del SDK (aapt, zipalign) son de 32 bits.
  $SUDO dpkg --add-architecture i386 || true
  $SUDO apt-get update -y || true
  $SUDO apt-get install -y --no-install-recommends libc6:i386 libstdc++6:i386 zlib1g:i386 \
    || warn "No pude instalar las librerias de 32 bits (puede que no hagan falta)."
}

install_sdk() {
  log "Android SDK (tools r25.2.5, $TARGET, build-tools $BUILD_TOOLS)"
  mkdir -p "$WORK"
  if [ ! -x "$SDK_DIR/tools/android" ]; then
    wget -q -O "$WORK/sdk-tools.zip" "$SDK_TOOLS_URL"
    mkdir -p "$SDK_DIR" && unzip -q -o "$WORK/sdk-tools.zip" -d "$SDK_DIR"
  fi
  export ANDROID_HOME="$SDK_DIR" ANDROID_SDK_ROOT="$SDK_DIR"
  export PATH="$SDK_DIR/tools:$SDK_DIR/tools/bin:$SDK_DIR/platform-tools:$SDK_DIR/build-tools/$BUILD_TOOLS:$PATH"
  yes | sdkmanager --licenses >/dev/null 2>&1 || true
  sdkmanager "platform-tools" "platforms;$TARGET" "build-tools;$BUILD_TOOLS" >/dev/null
  [ -f "$SDK_DIR/platforms/$TARGET/android.jar" ] || die "No se instalo la plataforma $TARGET"
}

install_ndk() {
  log "Android NDK r10e"
  if [ ! -x "$NDK_DIR/ndk-build" ]; then
    wget -q -O "$WORK/ndk.bin" "$NDK_URL"
    chmod +x "$WORK/ndk.bin"
    (cd "$WORK" && ./ndk.bin -y >/dev/null)
  fi
  [ -x "$NDK_DIR/ndk-build" ] || die "No se pudo extraer el NDK en $NDK_DIR"
  export ANDROID_NDK="$NDK_DIR" PATH="$NDK_DIR:$PATH"
}

prepare_workspace() {
  log "Preparando $WORK (misma estructura que el README)"
  rm -rf "$WORK/MCPELauncher"; mkdir -p "$WORK/MCPELauncher"
  tar -C "$REPO_DIR" --exclude=./.git --exclude=./out --exclude=./.github \
      --exclude=./bin --exclude=./gen --exclude=./obj -cf - . | tar -C "$WORK/MCPELauncher" -xf -

  mkdir -p "$WORK/aFileChooser" "$WORK/libsuperuser"
  clone_dep "$APP_URL"       "$WORK/MCPELauncher-app"        "$APP_REF"       "$DEPS_BEFORE"
  clone_dep "$AFILE_URL"     "$WORK/aFileChooser/_repo"      "$AFILE_REF"     "$DEPS_BEFORE"
  clone_dep "$SUPERUSER_URL" "$WORK/libsuperuser/_repo"      "$SUPERUSER_REF" "$DEPS_BEFORE"

  # README: aFileChooser/aFileChooser y libsuperuser/libsuperuser
  rm -rf "$WORK/aFileChooser/aFileChooser" "$WORK/libsuperuser/libsuperuser"
  if [ -d "$WORK/aFileChooser/_repo/aFileChooser" ]; then
    mv "$WORK/aFileChooser/_repo/aFileChooser" "$WORK/aFileChooser/aFileChooser"
  else
    mv "$WORK/aFileChooser/_repo" "$WORK/aFileChooser/aFileChooser"
  fi
  if [ -d "$WORK/libsuperuser/_repo/libsuperuser" ]; then
    mv "$WORK/libsuperuser/_repo/libsuperuser" "$WORK/libsuperuser/libsuperuser"
  else
    mv "$WORK/libsuperuser/_repo" "$WORK/libsuperuser/libsuperuser"
  fi

  ensure_lib_project "$WORK/aFileChooser/aFileChooser" aFileChooser com.ipaulpro.afilechooser
  ensure_lib_project "$WORK/libsuperuser/libsuperuser" libsuperuser eu.chainfire.libsuperuser
  printf 'sdk.dir=%s\n' "$SDK_DIR" | tee \
    "$WORK/MCPELauncher/local.properties" "$WORK/MCPELauncher-app/local.properties" \
    "$WORK/aFileChooser/aFileChooser/local.properties" "$WORK/libsuperuser/libsuperuser/local.properties" >/dev/null
}

build_native() {
  log "ndk-build (libmcpelauncher.so con Render API)"
  (cd "$WORK/MCPELauncher" && ndk-build -j"$(nproc)")
  [ -f "$WORK/MCPELauncher/libs/armeabi-v7a/libmcpelauncher.so" ] || die "ndk-build no genero libmcpelauncher.so"
}

build_apk() {
  log "android update project + ant debug"
  (cd "$WORK" && \
    android update lib-project -p libsuperuser/libsuperuser   -t "$TARGET" && \
    android update lib-project -p aFileChooser/aFileChooser   -t "$TARGET" && \
    android update lib-project -p MCPELauncher                -t "$TARGET" && \
    android update project     -p MCPELauncher-app            -t "$TARGET")
  (cd "$WORK/MCPELauncher-app" && ant clean debug)
}

collect_output() {
  log "Verificando y copiando el APK"
  local apk; apk="$(ls "$WORK"/MCPELauncher-app/bin/*-debug.apk 2>/dev/null | head -n1 || true)"
  [ -n "$apk" ] || die "ant no genero ningun *-debug.apk"
  unzip -l "$apk" | grep -q 'lib/armeabi-v7a/libmcpelauncher.so' || die "El APK no incluye libmcpelauncher.so"
  unzip -p "$apk" classes.dex | strings -a | grep -q 'NativeBlockRendererApi' \
    || die "El APK no contiene la Render API de bloques (NativeBlockRendererApi)"
  mkdir -p "$OUT_DIR"; cp "$apk" "$OUT_APK"
  log "LISTO: $OUT_APK"; ls -lh "$OUT_APK"
}

main() {
  check_java
  install_packages
  install_sdk
  install_ndk
  prepare_workspace
  build_native
  build_apk
  collect_output
}

# Solo ejecuta main si el script se lanza directamente (no si se hace "source").
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
