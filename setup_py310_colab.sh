#!/usr/bin/env bash
# setup_py310_venv.sh
# Colab 上に Python3.10 の専用 venv を作り、/usr/local/bin/python をその venv に固定。
# さらに Matplotlib の backend を Agg に強制し、A1111 WebUI がエラー無く起動できるよう
# 依存の下地（数値スタック＆Torch 2.1.2/cu121）を整えます。

set -euo pipefail

log(){ echo -e "\n\033[1;32m[INFO]\033[0m $*"; }
warn(){ echo -e "\n\033[1;33m[WARN]\033[0m $*"; }
err(){ echo -e "\n\033[1;31m[ERROR]\033[0m $*" >&2; }

SUDO=""
if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; fi

# ===== 設定 =====
VENV_DIR="${VENV_DIR:-/content/py310}"            # venv の設置先
PY_BIN_SYS="${PY_BIN_SYS:-python3.10}"            # システムの 3.10 実体
PY_BIN_VENV="$VENV_DIR/bin/python"
PIP_BIN_VENV="$VENV_DIR/bin/pip"
MPLCFG_DIR="/content/.mplconfig"
TORCH_VER="2.1.2"
TV_VER="0.16.2"
TORCH_IDX="https://download.pytorch.org/whl/cu121"
# =================

log "Installing Python 3.10 toolchain (venv, distutils, pip-whl)"
$SUDO apt-get update -y
$SUDO apt-get install -y software-properties-common >/dev/null 2>&1 || true
# （Colab は jammy なので python3.10 は標準提供。念のため）
$SUDO apt-get install -y python3.10 python3.10-venv python3.10-dev python3-distutils python3-pip-whl python3-setuptools-whl

# ----- venv 作成 & pip 更新 -----
if [ ! -d "$VENV_DIR" ]; then
  log "Creating venv at $VENV_DIR"
  $PY_BIN_SYS -m venv "$VENV_DIR"
else
  log "Reusing existing venv at $VENV_DIR"
fi

log "Upgrading pip/setuptools/wheel in venv"
"$PY_BIN_VENV" -m pip install --upgrade pip setuptools wheel

# ----- Matplotlib を headless(Agg) に固定 -----
log "Force Matplotlib non-interactive backend (Agg)"
mkdir -p "$MPLCFG_DIR"
echo "backend: Agg" > "$MPLCFG_DIR/matplotlibrc"

# sitecustomize でも保険をかける
SITEPKG=$("$PY_BIN_VENV" - <<'PY'
import site,sys,os
cands=[]
for f in (getattr(site,"getsitepackages",lambda:[]), lambda:[site.getusersitepackages()]):
    try:
        v=f()
        if isinstance(v,str): cands.append(v)
        else: cands.extend(v)
    except: pass
cands=[p for p in cands if "site-packages" in p]
print(cands[0] if cands else "")
PY
)
if [ -n "$SITEPKG" ]; then
  cat > "$SITEPKG/sitecustomize.py" <<'PY'
import os
# Colab が注入する inline backend を潰して Agg に固定
if os.environ.get("MPLBACKEND","").startswith("module://matplotlib_inline"):
    os.environ["MPLBACKEND"]="Agg"
# MPL の設定ディレクトリも固定（書込み不可エラー回避）
os.environ.setdefault("MPLCONFIGDIR","/content/.mplconfig")
try:
    import matplotlib
    if str(matplotlib.get_backend()).startswith("module://"):
        matplotlib.use("Agg", force=True)
except Exception:
    pass
PY
  chmod a+r "$SITEPKG/sitecustomize.py"
else
  warn "site-packages が見つからず、sitecustomize.py を配置できませんでした"
fi

# ----- /usr/local/bin/{python,pip} を venv に固定し、環境を無害化 -----
log "Install wrappers: /usr/local/bin/python & pip -> venv and MPLBACKEND=Agg"
$SUDO bash -lc "cat > /usr/local/bin/python <<'SH'
#!/usr/bin/env bash
# Clean env that confuses matplotlib/Colab
unset PYTHONHOME
unset PYTHONPATH
unset MPLBACKEND
export MPLBACKEND=Agg
export MPLCONFIGDIR=/content/.mplconfig
exec \"$VENV_DIR/bin/python\" \"\$@\"
SH
chmod +x /usr/local/bin/python"

$SUDO bash -lc "cat > /usr/local/bin/pip <<'SH'
#!/usr/bin/env bash
unset PYTHONHOME
unset PYTHONPATH
unset MPLBACKEND
exec \"$VENV_DIR/bin/pip\" \"\$@\"
SH
chmod +x /usr/local/bin/pip"

# ----- 数値スタックの下地を「堅い組合せ」で先に入れる（NumPy2系との互換事故回避） -----
log "Pre-pin numeric stack (numpy/scipy/mpl/scikit-image/pillow)"
"$PIP_BIN_VENV" install \
  'numpy==1.26.4' 'scipy==1.11.4' 'matplotlib==3.7.5' 'scikit-image==0.21.0' 'pillow==10.4.0'

# ----- Torch 2.1.2 (cu121) と torchvision を先に入れて WebUI の想定に合わせる -----
log "Installing PyTorch ${TORCH_VER} + torchvision ${TV_VER} (cu121 wheels)"
"$PIP_BIN_VENV" install --extra-index-url "$TORCH_IDX" \
  "torch==${TORCH_VER}" "torchvision==${TV_VER}"

# xformers はあると高速化。失敗しても続行。
log "Installing xformers (optional, best-effort)"
if ! "$PIP_BIN_VENV" install xformers==0.0.23.post1 >/dev/null 2>&1; then
  warn "xformers prebuilt wheel not available; skipping (WebUI は無しでも起動します)"
fi

# ----- GitHub の WebUI requirements に合わせて足りない物を軽く整える -----
# ユーザー提示の requirements に合わせ、未指定版は最新安定帯で導入。
log "Installing minimal deps that A1111 requires (besides torch)"
"$PIP_BIN_VENV" install \
  GitPython Pillow accelerate blendmodes clean-fid diskcache einops facexlib \
  "fastapi>=0.90.1" "gradio==3.41.2" inflection jsonmerge kornia lark numpy \
  omegaconf open-clip-torch piexif "protobuf==3.20.0" psutil pytorch_lightning \
  requests resize-right safetensors "scikit-image>=0.19" tomesd torchdiffeq torchsde \
  "transformers==4.30.2" "pillow-avif-plugin==1.4.3" \
  --upgrade --upgrade-strategy eager

# ----- 動作チェック -----
log "Sanity check (python & pip & mpl backend)"
python - <<'PY'
import sys, os, importlib
print("Python:", sys.version)
import torch, torchvision
print("Torch:", torch.__version__, "| CUDA available:", torch.cuda.is_available())
print("TorchVision:", torchvision.__version__)
print("MPLBACKEND env:", os.environ.get("MPLBACKEND"))
mpl = importlib.import_module("matplotlib")
print("Matplotlib backend:", mpl.get_backend())
PY

log "All set. Use this to launch A1111:"
echo '  %cd stable-diffusion-webui'
echo '  !COMMANDLINE_ARGS="--share --gradio-debug --enable-insecure-extension-access --disable-safe-unpickle" python launch.py'
