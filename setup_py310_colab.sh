#!/usr/bin/env bash
set -euo pipefail

log() { echo -e "\n\033[1;32m[INFO]\033[0m $*"; }
err() { echo -e "\n\033[1;31m[ERROR]\033[0m $*" >&2; }

SUDO=""; command -v sudo >/dev/null 2>&1 && SUDO="sudo"

# --- Paths ---
REPO_ROOT="/content/Aimaster_pydantic_v1"
REQ_FILE="$REPO_ROOT/requirements.txt"
VENV_DIR="/content/py310"
VENV_PY="$VENV_DIR/bin/python"
VENV_PIP="$VENV_DIR/bin/pip"

# --- 1) Install Python 3.10 toolchain (system) ---
log "Updating APT & installing Python 3.10 toolchain"
$SUDO apt-get update -y
$SUDO apt-get install -y software-properties-common
$SUDO add-apt-repository -y ppa:deadsnakes/ppa || true
$SUDO apt-get update -y
$SUDO apt-get install -y python3.10 python3.10-venv python3.10-dev python3.10-distutils

# --- 2) Create isolated venv (no touch to system site-packages) ---
if [ ! -d "$VENV_DIR" ]; then
  log "Creating venv at $VENV_DIR"
  python3.10 -m venv "$VENV_DIR"
fi

log "Upgrading pip/setuptools/wheel inside venv"
"$VENV_PY" -m pip install -U pip setuptools wheel

# --- 3) Pre-pin the numeric stack to avoid SciPy/Numpy breakage ---
#     Use versions known-good with Py3.10 & SD-WebUI deps.
log "Pre-pinning numeric stack (numpy/scipy/matplotlib/scikit-image/pillow)"
"$VENV_PIP" install \
  "numpy==1.26.4" \
  "scipy==1.11.4" \
  "matplotlib==3.7.5" \
  "scikit-image==0.21.0" \
  "pillow==10.4.0"

# --- 4) Install CUDA PyTorch in venv (so WebUI uses this torch) ---
#     cu126 wheels are broadly compatible on Colab (CUDA 12.x)
log "Installing PyTorch (CUDA) into venv"
"$VENV_PIP" install --index-url https://download.pytorch.org/whl/cu126 \
  "torch==2.8.0" "torchvision==0.23.0" || {
  log "Fallback: installing CPU wheels (no GPU wheels found)"
  "$VENV_PIP" install "torch==2.8.0" "torchvision==0.23.0"
}

# --- 5) Install your repo requirements inside the venv (keeps our pins) ---
if [ ! -f "$REQ_FILE" ]; then
  err "requirements.txt not found at ${REQ_FILE}"
  exit 1
fi
log "Installing $REQ_FILE into venv"
"$VENV_PIP" install -r "$REQ_FILE"

# --- 6) Force non-interactive Matplotlib backend via sitecustomize (venv only) ---
#     This survives across processes; no notebook env var edits needed.
SITEPKG="$("$VENV_PY" - <<'PY'
import site, sys
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
  log "Installing sitecustomize.py into: $SITEPKG"
  cat > "${SITEPKG}/sitecustomize.py" <<'PY'
import os
# Kill inline backend Colab sometimes injects; force Agg (headless)
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
else
  echo "[WARN] Could not locate site-packages for venv; backend fix skipped."
fi

# --- 7) Make 'python' on PATH point to the venv python -----------------------
#     Many SD-WebUI extensions call '/usr/local/bin/python' explicitly.
#     We redirect that absolute path to our venv to avoid touching system pkgs.
log "Pointing /usr/local/bin/python to venv python (needed by some extensions)"
$SUDO ln -sf "$VENV_PY" /usr/local/bin/python
$SUDO ln -sf "$VENV_PIP" /usr/local/bin/pip || true

# --- 8) Show versions --------------------------------------------------------
log "Venv Python: $("$VENV_PY" -V)"
log "Which python now used by shell: $(command -v python)"
python -V || true

log "Setup completed. You can now run Stable Diffusion WebUI normally."
