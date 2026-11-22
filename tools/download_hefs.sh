#!/bin/zsh
# Downloads the compiled Hailo-10H HEFs (Hailo Model Zoo v5.3.0) listed in native/all-hefs.txt into
# models/, 4 at a time, skipping ones already there (see fetch_hef.sh: kept only on HTTP 200 + HEF magic).
cd ${0:A:h}/..
xargs -P 4 -n 1 tools/fetch_hef.sh < native/all-hefs.txt
