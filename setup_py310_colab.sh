#!/usr/bin/env bash
set -euo pipefail

log() { echo -e "\n\033[1;32m[INFO]\033[0m $*"; }
err() { echo -e "\n\033[1;31m[ERROR]\033[0m $*" >&2; }

SUDO=""; command -v sudo >/dev/null 2>&1 && SUDO="sudo"

REPO_ROOT="/content/Aimaster_pydantic_v1"
REQ_FILE="$REPO_ROOT/requirements.txt"
VENV_DIR="/content/py310"
VENV_PY="$VENV_DIR/bin/python"
VENV_PIP="$VENV_DIR/bin/pip"

# 1) Python 3.10 を入れる
log "Installing Python 3.10 toolchain"
$SUDO apt-get update -y
$SUDO apt-get install -y software-properties-common
$SUDO add-apt-repository -y ppa:deadsnakes/ppa || true
$SUDO apt-get update -y
$SUDO apt-get install -y python3.10 python3.10-venv python3.10-dev python3.10-distutils

# 2) venv 作成
if [ ! -d "$VENV_DIR" ]; then
  log "Creating venv at $VENV_DIR"
  python3.10 -m venv "$VENV_DIR"
fi

# 3) venv 内に pip を必ず用意（ensurepip → get-pip.py フォールバック）
log "Ensuring pip exists inside venv"
if ! "$VENV_PY" -c "import pip" >/dev/null 2>&1; then
  "$VENV_PY" -m ensurepip --upgrade || true
fi
if ! "$VENV_PY" -c "import pip" >/dev/null 2>&1; then
  log "ensurepip failed; bootstrapping pip via get-pip.py"
  curl -sSfL https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py
  "$VENV_PY" /tmp/get-pip.py
fi

# 4) venv の pip をアップデート
"$VENV_PY" -m pip install -U pip setuptools wheel

# 5) 数値系は先に固定して衝突回避（NumPy/Scipy/Matplotlib 由来の落ちを防ぐ）
log "Pre-pinning numeric stack"
"$VENV_PIP" install \
  "numpy==1.26.4" \
  "scipy==1.11.4" \
  "matplotlib==3.7.5" \
  "scikit-image==0.21.0" \
  "pillow==10.4.0"

# ※ Torch は先に入れません（WebUI が自分で 2.1.2+cu121 を入れに行くため）
#   → ここで入れるとバージョン競合の原因になることがある

# 6) あなたのリポの依存を venv にインストール
if [ ! -f "$REQ_FILE" ]; then
  err "requirements.txt not found at ${REQ_FILE}"
  exit 1
fi
log "Installing $REQ_FILE into venv"
"$VENV_PIP" install -r "$REQ_FILE"

# 7) Matplotlib の backend を Agg に固定（ノートブック側を触らない）
SITEPKG="$("$VENV_PY" - <<'PY'
import site
cands=[]
for g in (getattr(site,'getsitepackages',lambda:[]),
          getattr(site,'getusersitepackages',lambda:'')):
    try:
        v=g(); cands.extend(v if isinstance(v,list) else [v])
    except Exception: pass
cands=[p for p in cands if p and 'site-packages' in p]
print(cands[0] if cands else '')
PY
)"
if [ -n "$SITEPKG" ]; then
  log "Writing sitecustomize.py to $SITEPKG"
  cat > "${SITEPKG}/sitecustomize.py" <<'PY'
import os
# Colab が入れる inline backend を無効化して Agg を強制
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

# 8) /usr/local/bin/python を venv 側に差し替え（拡張が絶対パス実行してもOK）
log "Pointing /usr/local/bin/python & pip to venv"
$SUDO ln -sf "$VENV_PY"  /usr/local/bin/python
$SUDO ln -sf "$VENV_PIP" /usr/local/bin/pip || true
hash -r || true

# 9) 動作確認
log "Check: python -m pip --version"
python -m pip --version
log "Check: which python -> $(command -v python)"
python -V

log "Setup completed. Launch WebUI as usual."
