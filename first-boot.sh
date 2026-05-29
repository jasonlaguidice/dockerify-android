#!/bin/bash

bool_true() {
  case "${1,,}" in
    1|true|yes) return 0 ;;
    *) return 1 ;;
  esac
}

apply_settings() {
  adb wait-for-device
  # Waiting for the boot sequence to be completed.
  COMPLETED=$(adb shell getprop sys.boot_completed | tr -d '\r')
  while [ "$COMPLETED" != "1" ]; do
    COMPLETED=$(adb shell getprop sys.boot_completed | tr -d '\r')
    sleep 5
  done
  adb root
  adb shell settings put global window_animation_scale 0
  adb shell settings put global transition_animation_scale 0
  adb shell settings put global animator_duration_scale 0
  adb shell settings put global stay_on_while_plugged_in 0
  adb shell settings put system screen_off_timeout 15000
  adb shell settings put system accelerometer_rotation 0
  adb shell settings put global private_dns_mode hostname
  adb shell settings put global private_dns_specifier ${DNS:-one.one.one.one}
  adb shell settings put global airplane_mode_on 1
  adb shell am broadcast -a android.intent.action.AIRPLANE_MODE --ez state true
  adb shell svc data disable
  adb shell svc wifi enable
}

prepare_system() {
  adb wait-for-device
  adb root
  adb shell avbctl disable-verification
  adb disable-verity
  adb reboot
  adb wait-for-device
  adb root
  adb remount
}

magisk_active() {
  # Magisk env is ready (binaries populated) — either by install_root in this
  # session or by a previously-rooted run. Empty /data/adb/magisk doesn't count.
  adb shell 'test -x /data/adb/magisk/magiskinit && echo MAGISK_READY' 2>/dev/null | grep -q MAGISK_READY
}

install_gapps_magisk_module() {
  echo "Installing GAPPS as a Magisk module ..."
  local MOD=/data/adb/modules/gapps
  adb push gapps-11/etc       /data/local/tmp/gapps-etc
  adb push gapps-11/framework /data/local/tmp/gapps-framework
  adb push gapps-11/app       /data/local/tmp/gapps-app
  adb push gapps-11/priv-app  /data/local/tmp/gapps-priv-app
  adb shell "
    rm -rf $MOD
    mkdir -p $MOD/system
    mv /data/local/tmp/gapps-etc       $MOD/system/etc
    mv /data/local/tmp/gapps-framework $MOD/system/framework
    mv /data/local/tmp/gapps-app       $MOD/system/app
    mv /data/local/tmp/gapps-priv-app  $MOD/system/priv-app
    cat > $MOD/module.prop <<'PROP'
id=gapps
name=PICO GAPPS
version=20220503
versionCode=20220503
author=Open GAPPS
description=Open GAPPS PICO for Android 11 x86_64
PROP
  "
}

install_gapps_system() {
  prepare_system
  adb push gapps-11/etc       /system
  adb push gapps-11/framework /system
  adb push gapps-11/app       /system
  adb push gapps-11/priv-app  /system
}

install_gapps() {
  adb wait-for-device
  adb root
  echo "Installing GAPPS ..."
  wget https://sourceforge.net/projects/opengapps/files/x86_64/20220503/open_gapps-x86_64-11.0-pico-20220503.zip/download -O gapps-11.zip
  unzip gapps-11.zip 'Core/*' -d gapps-11 && rm gapps-11.zip
  rm gapps-11/Core/setup*
  lzip -d gapps-11/Core/*.lz
  for f in gapps-11/Core/*.tar; do
    tar -x --strip-components 2 -f "$f" -C gapps-11
  done
  if magisk_active; then
    install_gapps_magisk_module
  else
    install_gapps_system
  fi
  rm -r gapps-11
  adb reboot
  adb wait-for-device
  touch /data/.gapps-done
}

install_root() {
  adb wait-for-device
  adb root
  echo "Root Script Starting..."
  # Root the AVD by patching the ramdisk.
  git clone https://gitlab.com/newbit/rootAVD.git
  pushd rootAVD
  sed -i 's/read -t 10 choice/choice=1/' rootAVD.sh
  ./rootAVD.sh system-images/android-30/default/x86_64/ramdisk.img
  cp /opt/android-sdk/system-images/android-30/default/x86_64/ramdisk.img /data/android.avd/ramdisk.img

  # Pre-populate /data/adb/magisk so Magisk's env-check passes on next boot.
  # rootAVD only patches the ramdisk; the "additional setup" tap in the Magisk
  # app would normally extract Magisk.zip into /data/adb/magisk/ (with the
  # lib*.so files renamed to their binary names). Doing it here means the next
  # QEMU restart comes up with a complete Magisk environment, no manual setup
  # prompt, and any modules in /data/adb/modules/ are loaded on boot.
  echo "Bootstrapping Magisk environment ..."
  rm -rf /tmp/magisk-stage
  mkdir -p /tmp/magisk-stage
  unzip -q -o Magisk.zip 'lib/*' 'assets/*' -d /tmp/magisk-stage
  pushd /tmp/magisk-stage/lib/x86_64
  for f in lib*.so; do mv "$f" "$(echo "$f" | sed -e 's/^lib//' -e 's/\.so$//')"; done
  cp -f ../x86/libmagisk32.so magisk32 2>/dev/null || true
  popd
  adb push /tmp/magisk-stage/lib/x86_64/. /data/local/tmp/magiskbin/
  adb push /tmp/magisk-stage/assets/.    /data/local/tmp/magiskbin/
  adb shell '
    mkdir -p /data/adb/magisk
    cp -a /data/local/tmp/magiskbin/. /data/adb/magisk/
    rm -f /data/adb/magisk/bootctl /data/adb/magisk/main.jar \
          /data/adb/magisk/module_installer.sh /data/adb/magisk/uninstaller.sh
    chmod -R 755 /data/adb/magisk
    rm -rf /data/local/tmp/magiskbin
  '
  rm -rf /tmp/magisk-stage

  popd
  echo "Root Done"
  sleep 10
  rm -r rootAVD
  touch /data/.root-done
}

install_arm_translation_magisk_module() {
  echo "Installing ARM translation as a Magisk module ..."
  local MOD=/data/adb/modules/ndk_translation
  adb push /opt/ndk-translation /data/local/tmp/ndk
  adb shell "
    rm -rf $MOD
    mkdir -p $MOD/system/bin $MOD/system/etc $MOD/system/lib $MOD/system/lib64
    cp -r /data/local/tmp/ndk/bin/.   $MOD/system/bin/
    cp -r /data/local/tmp/ndk/etc/.   $MOD/system/etc/
    cp -r /data/local/tmp/ndk/lib/.   $MOD/system/lib/
    cp -r /data/local/tmp/ndk/lib64/. $MOD/system/lib64/
    rm -rf /data/local/tmp/ndk
    chmod 755 $MOD/system/bin/ndk_translation_program_runner_binfmt_misc $MOD/system/bin/ndk_translation_program_runner_binfmt_misc_arm64
    chmod -R 755 $MOD/system/bin/arm $MOD/system/bin/arm64
    cat > $MOD/module.prop <<'PROP'
id=ndk_translation
name=NDK Translation (ARM on x86)
version=v0.2.3
versionCode=23
author=dockerify-android
description=Run ARM/ARM64 apps on x86_64 emulator via libndk_translation native bridge
PROP
    cat > $MOD/system.prop <<'PROP'
ro.product.cpu.abilist=x86_64,x86,arm64-v8a,armeabi-v7a,armeabi
ro.product.cpu.abilist32=x86,armeabi-v7a,armeabi
ro.product.cpu.abilist64=x86_64,arm64-v8a
ro.dalvik.vm.isa.arm=x86
ro.dalvik.vm.isa.arm64=x86_64
ro.enable.native.bridge.exec=1
ro.enable.native.bridge.exec64=1
ro.dalvik.vm.native.bridge=libndk_translation.so
ro.ndk_translation.version=0.2.3
PROP
    cat > $MOD/post-fs-data.sh <<'PFS'
#!/system/bin/sh
# init.rc files aren't parsed when injected via Magisk overlay (init scans
# /system/etc/init early, before module mounts). Register binfmt_misc here.
mount binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null
for f in arm_exe arm_dyn arm64_exe arm64_dyn; do
  [ -f \"\$MODPATH/system/etc/binfmt_misc/\$f\" ] &&
    cat \"\$MODPATH/system/etc/binfmt_misc/\$f\" > /proc/sys/fs/binfmt_misc/register 2>/dev/null
done
PFS
    chmod 755 $MOD/post-fs-data.sh
  "
}

install_arm_translation_system() {
  prepare_system
  echo "Installing ARM translation (ndk_translation) ..."

  adb push /opt/ndk-translation/bin   /system/
  adb push /opt/ndk-translation/etc   /system/
  adb push /opt/ndk-translation/lib   /system/
  adb push /opt/ndk-translation/lib64 /system/

  adb shell '
    chmod 755 /system/bin/ndk_translation_program_runner_binfmt_misc /system/bin/ndk_translation_program_runner_binfmt_misc_arm64
    chmod -R 755 /system/bin/arm /system/bin/arm64
    for f in /system/build.prop /vendor/build.prop /product/build.prop /system_ext/build.prop /odm/build.prop; do
      [ -f "$f" ] || continue
      sed -i -e "/^ro\.product\.cpu\.abilist/d" \
             -e "/^ro\.dalvik\.vm\.native\.bridge/d" \
             -e "/^ro\.enable\.native\.bridge/d" \
             -e "/^ro\.dalvik\.vm\.isa\./d" \
             -e "/^ro\.ndk_translation\./d" "$f"
    done
    cat >> /system/build.prop <<EOF
ro.product.cpu.abilist=x86_64,x86,arm64-v8a,armeabi-v7a,armeabi
ro.product.cpu.abilist32=x86,armeabi-v7a,armeabi
ro.product.cpu.abilist64=x86_64,arm64-v8a
ro.dalvik.vm.isa.arm=x86
ro.dalvik.vm.isa.arm64=x86_64
ro.enable.native.bridge.exec=1
ro.enable.native.bridge.exec64=1
ro.dalvik.vm.native.bridge=libndk_translation.so
ro.ndk_translation.version=0.2.3
EOF
  '
}

install_arm_translation() {
  adb wait-for-device
  adb root
  # On a live-Magisk device, /system is wrapped in a read-only magic mount;
  # install as a Magisk module so the changes land via Magisk's own overlay.
  if magisk_active; then
    install_arm_translation_magisk_module
  else
    install_arm_translation_system
  fi
  adb reboot
  adb wait-for-device
  touch /data/.arm-translation-done
}

copy_extras() {
  adb wait-for-device
  # Push any Magisk modules for manual installation later
  for f in /extras/*; do
    [ -e "$f" ] || continue
    adb push "$f" /sdcard/Download/
  done
}

# Detect the container's IP and forward ADB to localhost.
LOCAL_IP=$(ip addr list eth0 | grep "inet " | cut -d' ' -f6 | cut -d/ -f1)
socat tcp-listen:"5555",bind="$LOCAL_IP",fork tcp:127.0.0.1:"5555" &

gapps_needed=false
root_needed=false
arm_translation_needed=false
if bool_true "$GAPPS_SETUP" && [ ! -f /data/.gapps-done ]; then gapps_needed=true; fi
if bool_true "$ROOT_SETUP" && [ ! -f /data/.root-done ]; then root_needed=true; fi
if bool_true "$ARM_TRANSLATION" && [ ! -f /data/.arm-translation-done ]; then arm_translation_needed=true; fi

# Create the AVD on first boot only.
if [ ! -f /data/.first-boot-done ]; then
  echo "Init AVD ..."
  echo "no" | avdmanager create avd -n android -k "system-images;android-30;default;x86_64"
fi

# Each install is self-contained: prepares the system, applies its changes,
# reboots, waits for adbd, then writes its done-marker. Safe to run after the
# first boot — only the missing markers will fire.
#
# Root is installed first so it can bootstrap /data/adb/magisk/; the gapps
# and arm_translation installs then detect a ready Magisk env and write their
# payload to /data/adb/modules/<id>/ instead of /system. Modules sit dormant
# until the next QEMU restart loads the patched ramdisk and Magisk activates.
[ "$root_needed" = true ]            && install_root
[ "$gapps_needed" = true ]           && install_gapps
[ "$arm_translation_needed" = true ] && install_arm_translation
apply_settings
copy_extras

touch /data/.first-boot-done
echo "Success !!"
