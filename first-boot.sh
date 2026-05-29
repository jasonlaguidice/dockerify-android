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

install_gapps() {
  prepare_system
  echo "Installing GAPPS ..."
  wget https://sourceforge.net/projects/opengapps/files/x86_64/20220503/open_gapps-x86_64-11.0-pico-20220503.zip/download -O gapps-11.zip
  unzip gapps-11.zip 'Core/*' -d gapps-11 && rm gapps-11.zip
  rm gapps-11/Core/setup*
  lzip -d gapps-11/Core/*.lz
  for f in gapps-11/Core/*.tar; do
    tar -x --strip-components 2 -f "$f" -C gapps-11
  done
  adb push gapps-11/etc /system
  adb push gapps-11/framework /system
  adb push gapps-11/app /system
  adb push gapps-11/priv-app /system
  rm -r gapps-11
  adb reboot
  adb wait-for-device
  touch /data/.gapps-done
}

install_root() {
  adb wait-for-device
  echo "Root Script Starting..."
  # Root the AVD by patching the ramdisk.
  git clone https://gitlab.com/newbit/rootAVD.git
  pushd rootAVD
  sed -i 's/read -t 10 choice/choice=1/' rootAVD.sh
  ./rootAVD.sh system-images/android-30/default/x86_64/ramdisk.img
  cp /opt/android-sdk/system-images/android-30/default/x86_64/ramdisk.img /data/android.avd/ramdisk.img
  popd
  echo "Root Done"
  sleep 10
  rm -r rootAVD
  touch /data/.root-done
}

install_arm_translation() {
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
[ "$gapps_needed" = true ]           && install_gapps
[ "$root_needed" = true ]            && install_root
[ "$arm_translation_needed" = true ] && install_arm_translation
apply_settings
copy_extras

touch /data/.first-boot-done
echo "Success !!"
