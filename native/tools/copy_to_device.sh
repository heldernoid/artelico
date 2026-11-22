#!/bin/zsh
# Copies Core ML packages + their .native.json into Artelico's Documents/models on a device.
# usage: native/tools/copy_to_device.sh <device UDID> <list file> [skip-existing-list]
# (ARTELICO_BUNDLE_ID: the app's bundle identifier if you built it under your own prefix.)
cd "$(dirname $0)/../.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
device=$1; list=$2; skip=${3:-/dev/null}
for n in $(cat $list); do
  for f in native/coreml/$n.mlpackage native/coreml/$n.native.json; do
    [ -e $f ] || continue
    [[ $f == *.mlpackage ]] && grep -qx "$n" $skip && continue
    if xcrun devicectl device copy to --device $device --domain-type appDataContainer \
        --domain-identifier ${ARTELICO_BUNDLE_ID:-io.ugenkit.Artelico} --source $f --destination Documents/models/${f:t} >/dev/null 2>&1; then
      echo "ok   ${f:t}"
    else
      echo "FAIL ${f:t}"
    fi
  done
done
echo done
