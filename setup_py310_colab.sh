#!/usr/bin/env bash
set -euo pipefail

log() { echo -e "\n\033[1;32m[INFO]\033[0m $*"; }
err() { echo -e "\n\033[1;31m[ERROR]\033[0m $*" >&2; }

REPO_ROOT="/content/Aimaster_pydantic_v1"
REQ_FILE="$REPO_ROOT/requirements.txt"
VENV_DIR="/content/py310"
VENV_PY="$VENV_DIR/bin/python"
VENV_PIP="$VENV_DIR/bin/pip"

# 1) Python 3.10 を用意
log "Installing Python 3.10 toolchain"
apt-get update -y
apt-get install -y software-properties-common
add-apt-repository -y ppa:deadsnakes/ppa || true
apt-get update -y
apt-get install -y python3.10 python3.10-venv python3.10-dev python3-distutils

# 2) venv 作成
if [ ! -d "$VENV_DIR" ]; then
  log "Creating venv at $VENV_DIR"
  python3.10 -m venv "$VENV_DIR"
fi

# 3) venv に pip を必ず入れる（ensurepip → get-pip.py フォールバック）
log "Ensuring pip exists in venv"
if ! "$VENV_PY" -c "import pip" >/dev/null 2>&1; then
  "$VENV_PY" -m ensurepip --upgrade || true
fi
if ! "$VENV_PY" -c "import pip" >/dev/null 2>&1; then
  curl -sSfL https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py
  "$VENV_PY" /tmp/get-pip.py
fi

# 4) pip/セットアップ系を更新
"$VENV_PY" -m pip install -U pip setuptools wheel

# 5) 先に数値系を入れて足並みを揃える（SciPy/Numpy 周りの崩れ防止）
log "Pre-pinning numeric stack"
"$VENV_PIP" install \
  "numpy==1.26.4" \
  "scipy==1.11.4" \
  "matplotlib==3.7.5" \
  "scikit-image==0.21.0" \
  "pillow==10.4.0"

# 6) あなたの requirements を venv にインストール
if [ ! -f "$REQ_FILE" ]; then
  err "requirements.txt not found at $REQ_FILE"
  exit 1
fi
log "Installing $REQ_FILE into venv"
"$VENV_PIP" install -r "$REQ_FILE"

# 7) Matplotlib を非対話 backend に固定（ノートブック側は触らない）
SITEPKG="$("$VENV_PY" - <<'PY'
import site
c=[]
for g in (getattr(site,'getsitepackages',lambda:[]),
          getattr(site,'getusersitepackages',lambda:'')):
    try:
        v=g(); c.extend(v if isinstance(v,list) else [v])
    except Exception: pass
c=[p for p in c if p and 'site-packages' in p]
print(c[0] if c else '')
PY
)"
if [ -n "$SITEPKG" ]; then
  log "Writing sitecustomize.py to $SITEPKG"
  cat > "${SITEPKG}/sitecustomize.py" <<'PY'
import os
if os.environ.get("MPLBACKEND","").startswith("module://matplotlib_inline"):
    os.environ["MPLBACKEND"] = "Agg"
try:
    import matplotlib
    if str(matplotlib.get_backend()).startswith("module://"):
        matplotlib.use("Agg", force=True)
except Exception:
    pass
PY
  chmod a+r "${SITEPKG}/sitecustomize.py"
fi

# 8) /usr/local/bin/python/pip を「ラッパー」に置き換えて venv を強制
log "Installing wrapper /usr/local/bin/python -> $VENV_PY"
cat >/usr/local/bin/python <<SH
#!/usr/bin/env bash
unset PYTHONHOME
unset PYTHONPATH
exec "$VENV_PY" "\$@"
SH
chmod +x /usr/local/bin/python

log "Installing wrapper /usr/local/bin/pip -> $VENV_PIP"
cat >/usr/local/bin/pip <<SH
#!/usr/bin/env bash
unset PYTHONHOME
unset PYTHONPATH
exec "$VENV_PIP" "\$@"
SH
chmod +x /usr/local/bin/pip

# 9) 念のため /usr/local/bin/python に対しても pip を保証
/usr/local/bin/python -m ensurepip --upgrade || true
if ! /usr/local/bin/python -c "import pip" >/dev/null 2>&1; then
  curl -sSfL https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py
  /usr/local/bin/python /tmp/get-pip.py
fi
/usr/local/bin/python -m pip install -U pip setuptools wheel

# 10) 動作確認
log "Check: which python -> $(command -v python)"
log "Check: python -V    -> $(python -V 2>&1)"
log "Check: python -m pip --version"
python -m pip --version

log "Setup completed. Launch WebUI as usual (python launch.py)."
