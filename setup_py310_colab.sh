#!/usr/bin/env bash
set -euo pipefail

# ========= config =========
VENV_DIR="/content/py310"
WEBUI_DIR="/content/stable-diffusion-webui"
RUN_ARGS="--share --gradio-debug --enable-insecure-extension-access --disable-safe-unpickle"
# =========================

log() { echo -e "\n\033[1;32m[INFO]\033[0m $*"; }
err() { echo -e "\n\033[1;31m[ERROR]\033[0m $*" >&2; }

# Python 3.10 が無ければ最小限のパッケージを入れる
if ! command -v python3.10 >/dev/null 2>&1; then
  log "Installing Python 3.10 toolchain (apt)"
  sudo apt-get update -y
  sudo apt-get install -y python3.10 python3.10-dev python3.10-venv python3-pip
fi

# venv 作成
if [ ! -d "$VENV_DIR" ]; then
  log "Creating venv at $VENV_DIR"
  python3.10 -m venv "$VENV_DIR"
fi

# venv 有効化
source "$VENV_DIR/bin/activate"

# pip / build 基本ツール
log "Upgrading pip/setuptools/wheel"
python -m pip install --upgrade pip setuptools wheel

# --- Colab の matplotlib_inline バックエンド問題を sitecustomize で恒久対処 ---
SITE_DIR="$(python - <<'PY'
import site; p=site.getsitepackages(); print(p[0] if p else '')
PY
)"
if [ -z "${SITE_DIR}" ]; then
  err "site-packages not found"; exit 1
fi

log "Writing sitecustomize.py for MPL backend & PyTorch Lightning shim"
mkdir -p "${SITE_DIR}"
cat > "${SITE_DIR}/sitecustomize.py" <<'PY'
import os, sys, types
# 1) Colab が注入する inline backend を無効化して Agg を強制
if os.environ.get("MPLBACKEND","").startsWith("module://matplotlib_inline"):
    os.environ["MPLBACKEND"] = "Agg"
try:
    import matplotlib
    if str(matplotlib.get_backend()).startswith("module://"):
        matplotlib.use("Agg", force=True)
except Exception:
    pass

# 2) A1111 が参照しがちな古い import 互換:
#    from pytorch_lightning.utilities.distributed import rank_zero_only
try:
    import importlib
    try:
        import pytorch_lightning.utilities.distributed  # noqa
    except Exception:
        rz = importlib.import_module("pytorch_lightning.utilities.rank_zero")
        mod = types.ModuleType("pytorch_lightning.utilities.distributed")
        mod.rank_zero_only = getattr(rz, "rank_zero_only", None)
        sys.modules["pytorch_lightning.utilities.distributed"] = mod
except Exception:
    pass
PY

# 数値スタック（NumPy<2 系固定）先入れ
log "Pre-pinning numeric stack (NumPy<2 etc.)"
python -m pip install \
  numpy==1.26.4 \
  scipy==1.11.4 \
  matplotlib==3.7.5 \
  scikit-image==0.21.0 \
  pillow==10.4.0

# PyTorch（A1111 既定と整合：cu121 系）
log "Installing torch==2.1.2 / torchvision==0.16.2 (cu121)"
python -m pip install \
  torch==2.1.2 torchvision==0.16.2 \
  --extra-index-url https://download.pytorch.org/whl/cu121

# A1111 周辺の相性ピン
# - PL<2（ldm側の古い import に対応）
# - tokenizers<0.14（transformers==4.30.x と整合）
# - fastapi==0.90.1 / gradio==3.41.2 / protobuf==3.20.0 / pydantic==1 系
log "Pinning common deps for webui compatibility"
python -m pip install \
  "pytorch_lightning==1.9.5" \
  "tokenizers==0.13.3" \
  "fastapi==0.90.1" \
  "gradio==3.41.2" \
  "starlette==0.25.0" \
  "protobuf==3.20.0" \
  "pydantic==1.10.13"

# xformers は未インストール推奨（CUDA/PyTorch ビルド不一致の警告回避）
python - <<'PY'
import subprocess, sys
subprocess.call([sys.executable, "-m", "pip", "uninstall", "-y", "xformers"])
PY

# WebUI ディレクトリ確認
if [ ! -d "$WEBUI_DIR" ]; then
  err "Not found: ${WEBUI_DIR}   (git clone済みか確認してください)"
  exit 1
fi

# 実行ヘルパ（venv の Python を必ず使用）
RUN_WEBUI() {
  log "Launching AUTOMATIC1111 webui with venv python"
  cd "$WEBUI_DIR"
  export PYTHONNOUSERSITE=1
  export MPLBACKEND=Agg
  export XFORMERS_DISABLED=1
  exec "$VENV_DIR/bin/python" launch.py ${RUN_ARGS}
}

if [[ "${1:-}" == "--run-webui" ]]; then
  RUN_WEBUI
else
  log "Setup completed. To run webui:"
  echo "  !bash /content/Aimaster_pydantic_v1/setup_py310_venv.sh --run-webui"
fi
