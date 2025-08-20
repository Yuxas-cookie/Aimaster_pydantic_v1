#!/usr/bin/env bash
set -euo pipefail

# ====== config ======
VENV_DIR="/content/py310"
WEBUI_DIR="/content/stable-diffusion-webui"
RUN_ARGS="--share --gradio-debug --enable-insecure-extension-access --disable-safe-unpickle"
REQ_AIMASTER="/content/Aimaster_pydantic_v1/requirements.txt"
CONSTRAINTS="/tmp/constraints_a1111.txt"
# ====================

log(){ echo -e "\n\033[1;32m[INFO]\033[0m $*"; }
err(){ echo -e "\n\033[1;31m[ERROR]\033[0m $*" >&2; }
SUDO=""
if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; fi

need_pkg(){
  dpkg -s "$1" >/dev/null 2>&1 || return 0
  return 1
}

have_py310(){ command -v python3.10 >/dev/null 2>&1; }
have_ensurepip(){
  python3.10 - <<'PY' >/dev/null 2>&1 || exit 1
import importlib.util
ok = importlib.util.find_spec("venv") and importlib.util.find_spec("ensurepip")
raise SystemExit(0 if ok else 1)
PY
}

install_py310_stack(){
  log "Installing Python 3.10 toolchain via APT"
  $SUDO apt-get update -y
  $SUDO apt-get install -y python3.10 python3.10-dev python3.10-distutils || true
  $SUDO apt-get install -y python3.10-venv python3-pip
}

# --- 1) Python3.10 & ensurepip 確保 ---
if ! have_py310; then
  install_py310_stack
else
  if ! have_ensurepip; then
    log "python3.10-venv が必要です。APTで導入します。"
    $SUDO apt-get update -y
    $SUDO apt-get install -y python3.10-venv
  fi
fi

# 念のため ensurepip を最新化
python3.10 -m ensurepip --upgrade || true

# --- 2) venv 作成（ensurepip が無ければ再度Apt→再試行） ---
if [ ! -d "$VENV_DIR" ]; then
  log "Creating venv at $VENV_DIR"
  if ! python3.10 -m venv "$VENV_DIR"; then
    log "Retrying after ensuring python3.10-venv"
    $SUDO apt-get install -y python3.10-venv
    python3.10 -m venv "$VENV_DIR"
  fi
fi

# --- 3) venv 有効化 & 基本ツール ---
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"
log "Upgrading pip/setuptools/wheel"
python -m pip install --upgrade pip setuptools wheel

# --- 4) Colab の matplotlib_inline 問題 & PL 旧 import 互換を sitecustomize で吸収 ---
SITE_DIR="$(python - <<'PY'
import site; p=site.getsitepackages(); print(p[0] if p else '')
PY
)"
if [ -z "$SITE_DIR" ]; then err "site-packages が見つかりません"; exit 1; fi

log "Writing sitecustomize.py (MPL backend & PL shim)"
cat > "${SITE_DIR}/sitecustomize.py" <<'PY'
import os, sys, types
# 1) Colab の inline backend を Agg に固定
if os.environ.get("MPLBACKEND","").startswith("module://matplotlib_inline"):
    os.environ["MPLBACKEND"] = "Agg"
try:
    import matplotlib
    if str(matplotlib.get_backend()).startswith("module://"):
        matplotlib.use("Agg", force=True)
except Exception:
    pass

# 2) A1111 が参照する古い pytorch_lightning import を提供
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

# --- 5) A1111 と相性の良い依存を先に固定（Torch 2.1.2/cu121 等） ---
log "Pre-pinning numeric & core stack"
python -m pip install \
  "numpy==1.26.4" \
  "scipy==1.11.4" \
  "matplotlib==3.7.5" \
  "scikit-image==0.21.0" \
  "pillow==10.4.0"

log "Installing torch==2.1.2 / torchvision==0.16.2 (cu121 wheels)"
python -m pip install torch==2.1.2 torchvision==0.16.2 \
  --extra-index-url https://download.pytorch.org/whl/cu121

# A1111 の requirements（ユーザー提示）に合わせた固定
log "Pinning webui-aligned packages"
python -m pip install \
  "transformers==4.30.2" \
  "pytorch_lightning==1.9.5" \
  "protobuf==3.20.0" \
  "gradio==3.41.2" \
  "fastapi==0.90.1" \
  "pydantic==1.10.13" \
  "tokenizers==0.13.3" \
  "starlette==0.25.0"

# xformers 警告/不一致回避（使わない前提）
python -m pip uninstall -y xformers || true
export XFORMERS_DISABLED=1

# --- 6) Aimaster の要件を「制約付きで」導入（Torch等を上書きしない） ---
if [ -f "$REQ_AIMASTER" ]; then
  log "Writing constraints file: $CONSTRAINTS"
  cat > "$CONSTRAINTS" <<'TXT'
# Prevent upgrades that break AUTOMATIC1111 stack
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

  log "Installing Aimaster requirements with constraints"
  # 依存解決で torch などが上書きされないよう -c を併用
  PIP_PREFER_BINARY=1 python -m pip install -r "$REQ_AIMASTER" -c "$CONSTRAINTS"
else
  log "Skip Aimaster requirements (not found): $REQ_AIMASTER"
fi

# 念のため Matplotlib の rc も固定
mkdir -p ~/.config/matplotlib
echo "backend: Agg" > ~/.config/matplotlib/matplotlibrc

# --- 7) WebUI 実行ヘルパ（venv の python で起動） ---
RUN_WEBUI(){
  if [ ! -d "$WEBUI_DIR" ]; then
    err "Not found: ${WEBUI_DIR}  (先に git clone 済みか確認してください)"
    exit 1
  fi
  log "Launching AUTOMATIC1111 webui (venv python)"
  cd "$WEBUI_DIR"
  export PYTHONNOUSERSITE=1
  export MPLBACKEND=Agg
  export XFORMERS_DISABLED=1
  exec "$VENV_DIR/bin/python" launch.py ${RUN_ARGS}
}

if [[ "${1:-}" == "--run-webui" ]]; then
  RUN_WEBUI
else
  log "Setup completed."
  echo "To run webui:  !bash /content/Aimaster_pydantic_v1/setup_py310_venv.sh --run-webui"
fi
