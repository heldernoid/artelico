#!/bin/sh
# Downloads one Model Zoo source archive into native/src/<name>/. Used by prefetch_zoo.sh.
name=$1; url=$2
dir=native/src/$name; mkdir -p "$dir"; out="$dir/$(basename "$url")"
[ -s "$out" ] && exit 0
if curl -sfL --retry 3 -o "$out.prefetch" "$url"; then mv "$out.prefetch" "$out"; echo "got $name"; else rm -f "$out.prefetch"; echo "FAILED $name"; fi
