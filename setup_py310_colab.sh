#!/usr/bin/env bash
set -euo pipefail

log() { echo -e "\n\033[1;32m[INFO]\033[0m $*"; }
err() { echo -e "\n\033[1;31m[ERROR]\033[0m $*" >&2; }

SUDO=""
if command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
fi

export DEBIAN_FRONTEND=noninteractive
REQ_FILE="/content/Aimaster_pydantic_v1/requirements.txt"
CONSTRAINTS="/content/pip-constraints.txt"
WEBUI_DIR="/content/stable-diffusion-webui"

# ---------------- Python 3.10 準備 ----------------
log "Updating APT and preparing add-apt-repository..."
$SUDO apt-get update -y -qq
$SUDO apt-get install -y -qq software-properties-common

log "Adding deadsnakes PPA (ok to skip if already present)..."
$SUDO add-apt-repository -y ppa:deadsnakes/ppa || true
$SUDO apt-get update -y -qq

log "Installing Python 3.10 toolchain..."
$SUDO apt-get install -y -qq \
  python3.10 python3.10-dev python3.10-venv python3.10-distutils
$SUDO apt-get install -y -qq python3-pip

log "Bootstrapping pip/setuptools for Python 3.10..."
python3.10 -m ensurepip --upgrade || true
python3.10 -m pip install --upgrade pip setuptools wheel distlib --break-system-packages \
  || python3.10 -m pip install --upgrade pip setuptools wheel distlib

log "Switching default 'python' to Python 3.10..."
set +e
$SUDO update-alternatives --install /usr/bin/python python /usr/bin/python3.10 1
$SUDO update-alternatives --set python /usr/bin/python3.10
$SUDO ln -sf /usr/bin/python /usr/local/bin/python
set -e
hash -r || true
python -V

# ---------------- Aimaster 依存関係 ----------------
if [ ! -f "$REQ_FILE" ]; then
  err "requirements.txt not found at ${REQ_FILE}. Make sure the repo is cloned at /content/Aimaster_pydantic_v1"
  exit 1
fi

log "Installing requirements for Aimaster_pydantic_v1 with Python 3.10..."
python -m pip install -r "$REQ_FILE" --break-system-packages \
  || python -m pip install -r "$REQ_FILE"

# ---------------- NumPy/SciPy を将来も固定する制約ファイル ----------------
# ここで NumPy を 2.x に固定。SciPy/Matplotlib も互換確保のため緩く下限指定。
cat > "$CONSTRAINTS" <<'TXT'
# ---- Global constraints for SD-WebUI pip installs ----
numpy>=2.0,<2.3
scipy>=1.15
matplotlib>=3.8
TXT
chmod a+r "$CONSTRAINTS"
log "Wrote pip constraints to: $CONSTRAINTS"

# 参考までに現状を一度整える（この時点でも 2.x に上げておく）
python -m pip install "numpy>=2.0,<2.3" "scipy>=1.15" "matplotlib>=3.8" -U --no-input || true

# ---------------- Matplotlib backend (Agg) 強制 ----------------
log "Forcing matplotlib non-interactive backend (Agg) via rc + .pth hook"

mkdir -p ~/.config/matplotlib
echo "backend: Agg" > ~/.config/matplotlib/matplotlibrc

PY310_PURELIB=$(python3.10 - <<'PY'
import sys, sysconfig, site, os
cands=set()
try:
    paths=sysconfig.get_paths()
    if isinstance(paths, dict):
        for k in ('purelib','platlib'):
            v=paths.get(k,'');  v and cands.add(v)
except Exception: ...
try:
    for p in getattr(site,'getsitepackages', lambda: [])():
        cands.add(p)
except Exception: ...
try:
    cands.add(site.getusersitepackages())
except Exception: ...
for p in sys.path:
    if isinstance(p,str): cands.add(p)
cands=[p for p in cands if os.path.isdir(p) and '/python3.10/' in p and ('site-packages' in p or 'dist-packages' in p)]
cands=sorted(set(cands), key=lambda p: (0 if p.startswith('/usr/local') else 1, len(p)))
print(cands[0] if cands else '')
PY
)
[ -z "$PY310_PURELIB" ] && PY310_PURELIB="/usr/local/lib/python3.10/dist-packages"
log "Matplotlib fix target: $PY310_PURELIB"
$SUDO mkdir -p "$PY310_PURELIB"

cat <<'PY' | $SUDO tee "$PY310_PURELIB/_force_mpl_agg.py" >/dev/null
import os
if os.environ.get("MPLBACKEND", "").startswith("module://"):
    os.environ["MPLBACKEND"] = "Agg"
else:
    os.environ.setdefault("MPLBACKEND", "Agg")
try:
    import matplotlib
    matplotlib.use("Agg", force=True)
except Exception:
    pass
PY
echo "import _force_mpl_agg" | $SUDO tee "$PY310_PURELIB/zzz_force_mpl_agg.pth" >/dev/null
cat <<'PY' | $SUDO tee "$PY310_PURELIB/sitecustomize.py" >/dev/null
try:
    import _force_mpl_agg  # noqa
except Exception:
    pass
PY
$SUDO chmod a+r "$PY310_PURELIB/_force_mpl_agg.py" \
               "$PY310_PURELIB/zzz_force_mpl_agg.pth" \
               "$PY310_PURELIB/sitecustomize.py"

# 動作チェック
python - <<'PY'
import os
print("MPLBACKEND env:", os.environ.get("MPLBACKEND"))
try:
    import matplotlib
    print("matplotlib.get_backend():", matplotlib.get_backend())
except Exception as e:
    print("matplotlib import skipped/failed:", e)
PY

# ---------------- ★ WebUI の pip 呼び出しに constraints を強制注入 ★ ----------------
if [ -d "$WEBUI_DIR/modules" ] && [ -f "$WEBUI_DIR/modules/launch_utils.py" ]; then
  log "Patching WebUI pip runner to always use constraints: $CONSTRAINTS"
  PYFILE="$WEBUI_DIR/modules/launch_utils.py"
  BACKUP="$PYFILE.bak_constraints"

  # バックアップ
  cp -n "$PYFILE" "$BACKUP" || true

  # Python ワンライナーで安全に置換（--constraint を注入）
  python - <<PY
import io,sys,os,re
p=os.environ['PYFILE']
cfile=os.environ['CONSTRAINTS']
with open(p,'r',encoding='utf-8') as f: s=f.read()
# 既にパッチ済みなら何もしない
if cfile in s:
    print("Already patched."); sys.exit(0)
# 代表的な呼び出し箇所:
# return run(f'"{python}" -m pip {command} --prefer-binary{index_url_line}', ...)
pat = r'(-m pip )\{command\} (--prefer-binary\{index_url_line\})'
repl = r'\\1{command} -c "' + cfile.replace('\\','\\\\') + r'" \\2'
ns, n = re.subn(pat, repl, s)
if n==0:
    # 別バージョン対応: 同等の文字列をゆるく探す
    pat = r'(-m pip )\{command\} (.*?index_url_line.*?\})'
    ns, n = re.subn(pat, repl, s)
if n==0:
    print("WARNING: pattern not found; printing context and exiting without change.")
    print("\\n--- launch_utils.py head ---\\n", s[:5000])
    sys.exit(0)
with open(p,'w',encoding='utf-8') as f: f.write(ns)
print(f"Patched {p} (inserted -c {cfile})")
PY
else
  log "WebUI not found at $WEBUI_DIR yet; skip pip patch (run this script after cloning)."
fi

# ---------------- 仕上げ：バージョン表示 ----------------
python - <<'PY'
import numpy,sys
try:
    import scipy
    sp = scipy.__version__
except Exception:
    sp = "not-installed"
print("Python:", sys.version.split()[0])
print("NumPy :", numpy.__version__)
print("SciPy :", sp)
PY

log "All set. Launch WebUI as usual. NumPy will not be downgraded below 2.x anymore."
