#!/usr/bin/env bash
# setup_py310_colab.sh
set -euo pipefail
log(){ echo -e "\n\033[1;32m[INFO]\033[0m $*"; }
warn(){ echo -e "\n\033[1;33m[WARN]\033[0m $*"; }
err(){ echo -e "\n\033[1;31m[ERROR]\033[0m $*" 1>&2; }

VENV_DIR="/content/py310"
VENV_PY="${VENV_DIR}/bin/python"
VENV_PIP="${VENV_DIR}/bin/pip"
AIM_REPO_DIR="/content/Aimaster_pydantic_v1"
AIM_REQ="${AIM_REPO_DIR}/requirements.txt"
WEBUI_DIR="/content/stable-diffusion-webui"

# ---- Versions (CUDA 12.1 想定) ----
TORCH_VER="2.1.2"
TV_VER="0.16.2"
TORCH_EXTRA="--extra-index-url https://download.pytorch.org/whl/cu121"

TRANSFORMERS_VER="4.30.2"
PL_VER="1.9.4"
TOKENIZERS_VER="0.13.3"
GRADIO_VER="3.41.2"
PROTOBUF_VER="3.20.0"
PYDANTIC_VER="1.10.12"   # ★ 1.10.12 に変更（Aimaster と一致）
FASTAPI_VER="0.103.2"
STARLETTE_VER="0.27.0"

CONSTRAINTS_TXT="/content/.a1111_constraints.txt"
MATPLOTRC="${HOME}/.config/matplotlib/matplotlibrc"

RUN_WEBUI="0"
if [[ "${1-}" == "--run-webui" ]]; then RUN_WEBUI="1"; fi

log "Start setup_py310_colab.sh"
uname -a || true

log "Ensuring python3.10 and python3.10-venv are available"
sudo apt-get update -y
sudo apt-get install -y python3.10 python3.10-venv python3.10-distutils >/dev/null

if [[ ! -x "${VENV_PY}" ]]; then
  log "Creating venv at ${VENV_DIR}"
  python3.10 -m venv "${VENV_DIR}"
fi
log "Upgrading pip/setuptools/wheel in venv"
"${VENV_PY}" -m ensurepip --upgrade || true
"${VENV_PY}" -m pip install -U pip setuptools wheel

log "Forcing matplotlib non-interactive backend (Agg)"
mkdir -p "$(dirname "${MATPLOTRC}")"
echo "backend: Agg" > "${MATPLOTRC}"

SITE_PKGS="$("${VENV_PY}" - <<'PY'
import site
paths=[]
for getter in (getattr(site,"getsitepackages",lambda:[]), getattr(site,"getusersitepackages",lambda:"")):
  try:
    v=getter()
    if isinstance(v,str): paths.append(v)
    else: paths.extend(v)
  except Exception: pass
paths=[p for p in paths if p and "site-packages" in p]
print(paths[0] if paths else "")
PY
)"
if [[ -n "${SITE_PKGS}" ]]; then
  cat > "${SITE_PKGS}/sitecustomize.py" <<'PY'
import os
inline = "module://matplotlib_inline"
val = os.environ.get("MPLBACKEND","")
if val.startswith(inline):
    os.environ["MPLBACKEND"] = "Agg"
try:
    import matplotlib
    if str(matplotlib.get_backend()).startswith("module://"):
        matplotlib.use("Agg", force=True)
except Exception:
    pass
PY
fi

log "Disabling xformers to avoid CUDA/ABI mismatches"
/content/py310/bin/pip uninstall -y xformers >/dev/null 2>&1 || true
export XFORMERS_DISABLED=1

log "Writing constraints file to ${CONSTRAINTS_TXT}"
cat > "${CONSTRAINTS_TXT}" <<EOF
torch==${TORCH_VER}
torchvision==${TV_VER}
transformers==${TRANSFORMERS_VER}
pytorch_lightning==${PL_VER}
tokenizers==${TOKENIZERS_VER}
gradio==${GRADIO_VER}
protobuf==${PROTOBUF_VER}
pydantic==${PYDANTIC_VER}
fastapi==${FASTAPI_VER}
starlette==${STARLETTE_VER}
EOF

log "Installing torch==${TORCH_VER} / torchvision==${TV_VER} (cu121)"
"${VENV_PIP}" install "torch==${TORCH_VER}" "torchvision==${TV_VER}" ${TORCH_EXTRA}

log "Installing webui-aligned libs"
"${VENV_PIP}" install \
  "transformers==${TRANSFORMERS_VER}" \
  "pytorch_lightning==${PL_VER}" \
  "protobuf==${PROTOBUF_VER}" \
  "gradio==${GRADIO_VER}" \
  "pydantic==${PYDANTIC_VER}" \
  "tokenizers==${TOKENIZERS_VER}" \
  "fastapi==${FASTAPI_VER}" \
  "starlette==${STARLETTE_VER}"

if [[ -f "${AIM_REQ}" ]]; then
  log "Installing ${AIM_REQ} with constraints (no version drift)"
  "${VENV_PIP}" install -r "${AIM_REQ}" -c "${CONSTRAINTS_TXT}"
else
  warn "Not found: ${AIM_REQ}"
fi

export PYTHONNOUSERSITE=1
export MPLBACKEND=Agg
export HF_HUB_DISABLE_TELEMETRY=1
export GRADIO_ANALYTICS_ENABLED="false"
export PIP_NO_INPUT=1
export PIP_DISABLE_PIP_VERSION_CHECK=1

log "Python in venv: $("${VENV_PY}" -V)"
log "torch:        $("${VENV_PY}" -c 'import torch,sys;print(torch.__version__, torch.version.cuda, sys.version.split()[0])' || true)"
log "PL/transformers/gradio/fastapi/starlette:"
"${VENV_PY}" - <<'PY' || true
import importlib
mods = ["pytorch_lightning","transformers","gradio","fastapi","starlette","pydantic","tokenizers","protobuf"]
for m in mods:
    try:
        mod = importlib.import_module(m)
        v = getattr(mod,"__version__",None) or getattr(mod,"version",None)
        print(f"{m:20s} {v}")
    except Exception as e:
        print(f"{m:20s} (import error: {e})")
PY

if [[ "${RUN_WEBUI}" == "1" ]]; then
  if [[ ! -d "${WEBUI_DIR}" ]]; then
    err "WebUI directory not found: ${WEBUI_DIR}"
    exit 1
  fi
  log "Launching A1111 WebUI"
  cd "${WEBUI_DIR}"
  export PYTHON="${VENV_PY}"
  export TORCH_COMMAND="echo 'torch preinstalled'"
  export REQS_FILE="requirements.txt"
  export COMMANDLINE_ARGS="--share --gradio-debug --enable-insecure-extension-access --disable-safe-unpickle"
  export XFORMERS_DISABLED=1
  export MPLBACKEND=Agg
  export PYTHONNOUSERSITE=1
  "${VENV_PY}" launch.py
fi
log "Done."
