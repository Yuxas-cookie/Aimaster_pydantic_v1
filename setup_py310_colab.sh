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

if [ ! -f "$REQ_FILE" ]; then
  err "requirements.txt not found at ${REQ_FILE}. Make sure the repo is cloned at /content/Aimaster_pydantic_v1"
  exit 1
fi

log "Installing requirements for Aimaster_pydantic_v1 with Python 3.10..."
# --break-system-packages は失敗する環境もあるのでフォールバック付き
python -m pip install -r "$REQ_FILE" --break-system-packages \
  || python -m pip install -r "$REQ_FILE"

log "Done. Current python is: $(python -V 2>&1)"

# =====================================================================
# Matplotlib backend 強制 (Colab 側のセル変更なしで効く堅牢版)
#   1) ~/.config/matplotlib で Agg を指定（参考用）
#   2) dist-/site-packages に .pth フックを設置 → Python 起動時に必ず実行
#   3) フォールバックとして sitecustomize でも実行
# =====================================================================
log "Forcing matplotlib non-interactive backend (Agg) via rc + .pth hook"

# 参考: ユーザ設定（なくてもOK、あると読みやすい）
mkdir -p ~/.config/matplotlib
echo "backend: Agg" > ~/.config/matplotlib/matplotlibrc

# どの site ディレクトリに入れるかを堅牢に探索
PY310_PURELIB=$(python3.10 - <<'PY'
import sys, sysconfig, site, os
cands=set()

# sysconfig 経由
try:
    paths=sysconfig.get_paths()
    if isinstance(paths, dict):
        for k in ('purelib','platlib'):
            v=paths.get(k,'')
            if v: cands.add(v)
except Exception:
    pass

# site 経由
try:
    for p in getattr(site,'getsitepackages', lambda: [])():
        cands.add(p)
except Exception:
    pass
try:
    cands.add(site.getusersitepackages())
except Exception:
    pass

# sys.path からも拾う
for p in sys.path:
    if isinstance(p,str):
        cands.add(p)

# Python3.10 の dist/site-packages っぽいところだけ残す
cands=[p for p in cands if isinstance(p,str) and os.path.isdir(p) and
       ('/python3.10/' in p) and ('site-packages' in p or 'dist-packages' in p)]

# /usr/local を優先、次に長さ優先（より具体的なパス）
cands=sorted(set(cands), key=lambda p: (0 if p.startswith('/usr/local') else 1, len(p)))
print(cands[0] if cands else '')
PY
)

# 無ければ一般的な Colab の既定パスにフォールバック
if [ -z "$PY310_PURELIB" ]; then
  PY310_PURELIB="/usr/local/lib/python3.10/dist-packages"
fi

log "Matplotlib fix target: $PY310_PURELIB"
$SUDO mkdir -p "$PY310_PURELIB"

# 実処理: backend を Agg に強制する小モジュール
cat <<'PY' | $SUDO tee "$PY310_PURELIB/_force_mpl_agg.py" >/dev/null
import os
# Colab/Jupyter が注入する inline backend を無条件で Agg に置き換える
if os.environ.get("MPLBACKEND", "").startswith("module://"):
    os.environ["MPLBACKEND"] = "Agg"
else:
    # 指定がなければ Agg をセット
    os.environ.setdefault("MPLBACKEND", "Agg")

try:
    import matplotlib
    matplotlib.use("Agg", force=True)
except Exception:
    # matplotlib 未インストールでも問題なし
    pass
PY

# Python 起動時に必ず上のモジュールを import させる .pth フック
echo "import _force_mpl_agg" | $SUDO tee "$PY310_PURELIB/zzz_force_mpl_agg.pth" >/dev/null

# フォールバック: sitecustomize 経由でも読み込む
cat <<'PY' | $SUDO tee "$PY310_PURELIB/sitecustomize.py" >/dev/null
try:
    import _force_mpl_agg  # noqa
except Exception:
    pass
PY

$SUDO chmod a+r "$PY310_PURELIB/_force_mpl_agg.py" \
               "$PY310_PURELIB/zzz_force_mpl_agg.pth" \
               "$PY310_PURELIB/sitecustomize.py"

# 動作テスト（Agg が返ればOK）
python - <<'PY'
import os
import sys
print("MPLBACKEND env:", os.environ.get("MPLBACKEND"))
try:
    import matplotlib
    print("matplotlib.get_backend():", matplotlib.get_backend())
except Exception as e:
    print("matplotlib import skipped/failed:", e)
PY

log "All set. You can now run your existing cells without changes."
