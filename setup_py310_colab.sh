#!/usr/bin/env bash
set -eEuo pipefail
export DEBIAN_FRONTEND=noninteractive

# ===== visible, robust logging =====
log(){ echo -e "\n\033[1;32m[INFO]\033[0m $*"; }
err(){ echo -e "\n\033[1;31m[ERROR]\033[0m $*" >&2; }
trap 'code=$?; err "Failed at line $LINENO (exit $code)"; exit $code' ERR

# ===== config =====
VENV_DIR="/content/py310"
WEBUI_DIR="/content/stable-diffusion-webui"
RUN_ARGS="--share --gradio-debug --enable-insecure-extension-access --disable-safe-unpickle"
REQ_AIMASTER="/content/Aimaster_pydantic_v1/requirements.txt"
CONSTRAINTS="/tmp/constraints_a1111.txt"
PYTHON_BIN="python3.10"
SUDO=""
command -v sudo >/dev/null 2>&1 && SUDO="sudo"

log "Start setup_py310_colab.sh"
uname -a || true
$PYTHON_BIN -V || true

# ----- helpers -----
have_py310(){ command -v $PYTHON_BIN >/dev/null 2>&1; }
have_ensurepip(){
  $PYTHON_BIN - <<'PY' >/dev/null 2>&1
import importlib.util, sys
ok = importlib.util.find_spec("venv") and importlib.util.find_spec("ensurepip")
sys.exit(0 if ok else 1)
PY
}

install_py310_stack(){
  log "Installing Python 3.10 stack via APT"
  $SUDO apt-get update -y
  $SUDO apt-get install -y python3.10 python3.10-dev python3.10-distutils || true
  $SUDO apt-get install -y python3.10-venv python3-pip
}

# ----- 1) Python 3.10 と ensurepip の確保 -----
if ! have_py310; then
  log "python3.10 not found -> installing"
  install_py310_stack
else
  log "python3.10 found"
  if ! have_ensurepip; then
    log "ensurepip/venv is missing -> installing python3.10-venv"
    $SUDO apt-get update -y
    $SUDO apt-get install -y python3.10-venv
  fi
fi

# 念のため
$PYTHON_BIN -m ensurepip --upgrade || true

# ----- 2) venv 作成 -----
if [ ! -d "$VENV_DIR" ]; then
  log "Creating venv at $VENV_DIR"
  if ! $PYTHON_BIN -m venv "$VENV_DIR"; then
    log "Retry venv after (re)installing python3.10-venv"
    $SUDO apt-get install -y python3.10-venv
    $PYTHON_BIN -m venv "$VENV_DIR"
  fi
else
  log "venv already exists at $VENV_DIR"
fi

# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"
export PYTHONUNBUFFERED=1
log "Python in venv: $(python -V)"

# pip/toolchain
log "Upgrading pip / setuptools / wheel in venv"
python -m pip install --upgrade pip setuptools wheel

# ----- 3) Colab特有の backend 問題 & PL 旧import を sitecustomize で吸収 -----
SITE_DIR="$(python - <<'PY'
import site; p=site.getsitepackages(); print(p[0] if p else '')
PY
)"
[ -z "$SITE_DIR" ] && SITE_DIR="$VENV_DIR/lib/python3.10/site-packages"

log "Writing sitecustomize.py to: $SITE_DIR"
cat > "${SITE_DIR}/sitecustomize.py" <<'PY'
import os, sys, types
# 1) Force non-interactive backend for matplotlib in Colab
if os.environ.get("MPLBACKEND","").startswith("module://matplotlib_inline"):
    os.environ["MPLBACKEND"] = "Agg"
try:
    import matplotlib
    if str(matplotlib.get_backend()).startswith("module://"):
        matplotlib.use("Agg", force=True)
except Exception:
    pass

# 2) Provide legacy import path for AUTOMATIC1111 (PL <-> rank_zero shim)
try:
    import importlib
    try:
        import pytorch_lightning.utilities.distributed  # noqa: F401
    except Exception:
        rz = importlib.import_module("pytorch_lightning.utilities.rank_zero")
        mod = types.ModuleType("pytorch_lightning.utilities.distributed")
        mod.rank_zero_only = getattr(rz, "rank_zero_only", None)
        sys.modules["pytorch_lightning.utilities.distributed"] = mod
except Exception:
    pass
PY

mkdir -p ~/.config/matplotlib
echo "backend: Agg" > ~/.config/matplotlib/matplotlibrc

# ----- 4) A1111 に合わせて先に土台を固定（Torch 2.1.2/cu121 等）-----
log "Pre-pinning numeric/core stack"
python -m pip install \
  "numpy==1.26.4" \
  "scipy==1.11.4" \
  "matplotlib==3.7.5" \
  "scikit-image==0.21.0" \
  "pillow==10.4.0"

log "Installing torch==2.1.2 / torchvision==0.16.2 (cu121)"
python -m pip install torch==2.1.2 torchvision==0.16.2 \
  --extra-index-url https://download.pytorch.org/whl/cu121

log "Pinning webui-aligned libs"
python -m pip install \
  "transformers==4.30.2" \
  "pytorch_lightning==1.9.5" \
  "protobuf==3.20.0" \
  "gradio==3.41.2" \
  "fastapi==0.90.1" \
  "pydantic==1.10.13" \
  "tokenizers==0.13.3" \
  "starlette==0.25.0"

# xformers は無効化（不一致警告を避ける）
python -m pip uninstall -y xformers || true
export XFORMERS_DISABLED=1

# ----- 5) Aimaster の requirements を制約付きで導入（上書きを防止）-----
if [ -f "$REQ_AIMASTER" ]; then
  log "Writing constraints file: $CONSTRAINTS"
  cat > "$CONSTRAINTS" <<'TXT'
torch==2.1.2
torchvision==0.16.2
numpy==1.26.4
scipy==1.11.4
matplotlib==3.7.5
pytorch_lightning==1.9.5
transformers==4.30.2
protobuf==3.20.0
gradio==3.41.2
fastapi==0.90.1
pydantic==1.10.13
tokenizers==0.13.3
starlette==0.25.0
TXT

  log "Installing /content/Aimaster_pydantic_v1/requirements.txt with constraints"
  PIP_PREFER_BINARY=1 python -m pip install -r "$REQ_AIMASTER" -c "$CONSTRAINTS"
else
  log "Skip Aimaster requirements (not found): $REQ_AIMASTER"
fi

# ----- 6) WebUI 起動関数（venvのpythonで実行）-----
RUN_WEBUI(){
  [ -d "$WEBUI_DIR" ] || { err "Not found: ${WEBUI_DIR} (git clone 済みか確認)"; exit 1; }
  log "Launching AUTOMATIC1111 webui with venv python"
  cd "$WEBUI_DIR"
  export PYTHONNOUSERSITE=1
  export MPLBACKEND=Agg
  export XFORMERS_DISABLED=1
  exec "$VENV_DIR/bin/python" launch.py ${RUN_ARGS}
}

# ----- 7) 引数で制御 -----
if [[ "${1:-}" == "--run-webui" ]]; then
  RUN_WEBUI
else
  log "Setup completed. To run webui:"
  echo "!stdbuf -oL -eL bash -x /content/Aimaster_pydantic_v1/setup_py310_colab.sh --run-webui 2>&1 | tee /content/py310_setup.log"
fi
