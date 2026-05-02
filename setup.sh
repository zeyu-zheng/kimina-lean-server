#!/usr/bin/env bash
set -euxo pipefail

if [ -f .env ]; then
  set -a
  . ./.env
  set +a
fi

LEAN_SERVER_LEAN_VERSION="${LEAN_SERVER_LEAN_VERSION:-v4.26.0}"
REPL_REPO_URL="${REPL_REPO_URL:-https://github.com/leanprover-community/repl.git}"
REPL_BRANCH="${REPL_BRANCH:-$LEAN_SERVER_LEAN_VERSION}"
MATHLIB_REPO_URL="${MATHLIB_REPO_URL:-https://github.com/leanprover-community/mathlib4.git}"
MATHLIB_BRANCH="${MATHLIB_BRANCH:-$LEAN_SERVER_LEAN_VERSION}"

command -v curl >/dev/null 2>&1 || { echo >&2 "curl is required"; exit 1; }
command -v git  >/dev/null 2>&1 || { echo >&2 "git is required";  exit 1; }

# Install Elan only if not already present (elan-init.sh prompts on existing
# installs which breaks ``set -e``). When elan is there we just ensure the
# requested toolchain is on disk via ``elan toolchain install``, which is a
# no-op if already cached.
if command -v elan >/dev/null 2>&1; then
  echo "elan already installed: $(elan --version)"
else
  echo "Installing Elan"
  curl https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh -sSf \
    | sh -s -- --default-toolchain "${LEAN_SERVER_LEAN_VERSION}" -y
fi
source "$HOME/.elan/env"
elan toolchain install "${LEAN_SERVER_LEAN_VERSION}" >/dev/null

echo "Installing Lean ${LEAN_SERVER_LEAN_VERSION}"
lean +"${LEAN_SERVER_LEAN_VERSION}" --version

# Version comparison function - only proceeds if args are in vX.Y.Z format.
version_lte() {
  local ver1="$1"
  local ver2="$2"
  
  # Check if both versions match pattern vX.Y.Z
  if ! [[ "$ver1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || ! [[ "$ver2" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    return 1  # Return false if either version doesn't match pattern
  fi
  
  # Strip 'v' prefix and compare versions.
  local v1="${ver1#v}"
  local v2="${ver2#v}"
  printf '%s\n%s\n' "$v1" "$v2" | sort -V -C
}

install_repo() {
  local name="$1" url="$2" branch="$3" upd_manifest="$4"
  echo "Installing ${name}@${branch}..."
  if [ ! -d "$name/.git" ]; then
    rm -rf "$name"
    git clone --branch "${branch}" --single-branch --depth 1 "$url" "$name"
  fi
  pushd "$name"
    # Skip the branch checkout if HEAD is already a descendant of the
    # requested branch tip -- preserves cherry-picks already applied to repl/
    # (e.g. the EOL-flush patch below) across re-runs.
    target_sha=$(git rev-parse --verify "${branch}^{commit}" 2>/dev/null || true)
    head_sha=$(git rev-parse HEAD)
    if [ -z "$target_sha" ] || ! git merge-base --is-ancestor "$target_sha" "$head_sha"; then
      git checkout "${branch}"
    else
      echo "HEAD ($head_sha) already includes ${branch} ($target_sha); skipping checkout"
    fi
    if [ "$name" = "mathlib4" ]; then
      # ``lake exe cache get`` builds the cache binary which triggers
      # dependency fetch; mathlib4's manifest pins commits that have been
      # force-pushed off their branches (e.g. Qq's ``bump toolchain``) and
      # ``git clone`` alone won't have them, so pre-fetch each pinned SHA by
      # hand. GitHub keeps unreachable commits accessible by SHA for ~30d.
      python3 - <<'PY'
import json, os, subprocess, sys
manifest = json.load(open("lake-manifest.json"))
for pkg in manifest["packages"]:
    pname, purl, prev = pkg["name"], pkg["url"], pkg["rev"]
    dest = f".lake/packages/{pname}"
    if not os.path.isdir(os.path.join(dest, ".git")):
        print(f"  pre-fetch {pname} @ {prev[:8]}", flush=True)
        subprocess.check_call(["git", "clone", purl, dest])
        subprocess.check_call(["git", "-C", dest, "fetch", "origin", prev])
PY
      lake exe cache get
    fi
    lake build
    if [ "$upd_manifest" = "true" ]; then
      jq '.packages |= map(.type="path"|del(.url)|.dir=".lake/packages/"+.name)' \
         lake-manifest.json > lake-manifest.json.tmp && mv lake-manifest.json.tmp lake-manifest.json
    fi
  popd
}

install_repo repl "$REPL_REPO_URL" "$REPL_BRANCH" false

# Cherry-pick EOL flush commit for v4.9.0 and under (incl. v4.9.0-rc* prereleases,
# which version_lte's vX.Y.Z regex doesn't accept). ``-X theirs`` auto-resolves
# the trivial v4.9.0-rc1 conflict (the patch's parent has minor cosmetic drift
# from the v4.9.0-rc1 tag); the resolution is exactly what we want anyway.
# Idempotent: skipped once ``printFlush`` is already in REPL/Main.lean.
if version_lte "$REPL_BRANCH" "v4.9.0" || [[ "$REPL_BRANCH" == v4.9.0-rc* ]]; then
  if grep -q 'printFlush' repl/REPL/Main.lean 2>/dev/null; then
    echo "EOL-flush patch already applied to repl/; skipping cherry-pick"
  else
    echo "Applying commit 4fc1e6d1dda170e8f0a6b698dd5f7e17a9cf52b4 for $REPL_BRANCH (<=v4.9.0)..."
    pushd repl
      git fetch origin 4fc1e6d1dda170e8f0a6b698dd5f7e17a9cf52b4
      git -c user.name="kimina-lean-server" -c user.email="setup@kimina-lean-server" \
        cherry-pick -X theirs 4fc1e6d1dda170e8f0a6b698dd5f7e17a9cf52b4
      lake build
    popd
  fi
fi

install_repo mathlib4 "$MATHLIB_REPO_URL" "$MATHLIB_BRANCH" true
