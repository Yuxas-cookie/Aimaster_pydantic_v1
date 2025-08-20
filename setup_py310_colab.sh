#!/usr/bin/env bash
set -euo pipefail

log() { echo -e "\n\033[1;32m[INFO]\033[0m $*"; }
err() { echo -e "\n\033[1;31m[ERROR]\033[0m $*" >&2; }

SUDO=""
if command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
fi

REQ_FILE="/content/Aimaster_pydantic_v1/requirements.txt"

log "Updating APT and preparing add-apt-repository..."
$SUDO apt-get update -y
$SUDO apt-get install -y software-properties-common

log "Adding deadsnakes PPA (ok to skip if already present)..."
$SUDO add-apt-repository -y ppa:deadsnakes/ppa || true
$SUDO apt-get update -y

log "Installing Python 3.10 toolchain..."
$SUDO apt-get install -y \
  python3.10 python3.10-dev python3.10-venv python3.10-distutils
$SUDO apt-get install -y python3-pip

log "Bootstrapping pip/setuptools for Python 3.10..."
python3.10 -m ensurepip --upgrade || true
python3.10 -m pip install --upgrade pip setuptools wheel distlib \
  --break-system-packages || python3.10 -m pip install --upgrade pip setuptools wheel distlib

log "Switching default 'python' to Python 3.10..."
$SUDO update-alternatives --install /usr/bin/python python /usr/bin/python3.10 1 || true
$SUDO update-alternatives --set python /usr/bin/python3.10 || true
$SUDO ln -sf /usr/bin/python /usr/local/bin/python || true
hash -r || true
python -V

if [ ! -f "$REQ_FILE" ]; then
  err "requirements.txt not found at ${REQ_FILE}. Make sure the repo is cloned at /content/Aimaster_pydantic_v1"
  exit 1
fi

log "Installing requirements for Aimaster_pydantic_v1 with Python 3.10..."
python -m pip install -r "$REQ_FILE" --break-system-packages || python -m pip install -r "$REQ_FILE"

log "Done. Current python is: $(python -V 2>&1)"

log "Forcing matplotlib non-interactive backend"
mkdir -p ~/.config/matplotlib
echo "backend: Agg" > ~/.config/matplotlib/matplotlibrc
