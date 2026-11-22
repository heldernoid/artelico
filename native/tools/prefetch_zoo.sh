#!/bin/zsh
# Downloads the Model Zoo source archives for native/todo-convert.txt, 4 at a time, into
# native/src/<name>/ so convert_all.py finds them ready (it skips archives that already exist).
cd ${0:A:h}/../..
python3 -c "
import json
cfg = {c['name']: c for c in json.load(open('native/zoo-configs.json'))}
for n in open('native/todo-convert.txt').read().split():
    u = (cfg.get(n) or {}).get('url')
    if u: print(n, u)
" | xargs -P 4 -n 2 native/tools/fetch_zoo_archive.sh
