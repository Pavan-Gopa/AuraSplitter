#!/usr/bin/env bash
# OPT_PERF git checkpoints: pre-step / post-approve commit + tag + push.
# Usage:
#   ./script/opt_checkpoint.sh pre K0
#   ./script/opt_checkpoint.sh post K0 "short description"
#   ./script/opt_checkpoint.sh list
#   ./script/opt_checkpoint.sh rollback pre K1
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

die() { echo "error: $*" >&2; exit 1; }

require_step() {
  local step="${1:-}"
  [[ "$step" =~ ^K[0-8]$|^OPT_DONE$ ]] || die "step must be K0..K8 or OPT_DONE, got: ${step:-empty}"
}

git_ok() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repository"
}

has_remote() {
  git remote get-url origin >/dev/null 2>&1
}

push_all() {
  local tag="$1"
  if has_remote; then
    echo "→ git push origin HEAD"
    git push -u origin HEAD
    echo "→ git push origin $tag"
    git push origin "$tag"
  else
    echo "warn: no origin remote — commit/tag local only"
  fi
}

commit_if_dirty() {
  local message="$1"
  git status --porcelain
  if [[ -n "$(git status --porcelain)" ]]; then
    git add -A
    # Do not commit if still nothing staged (e.g. ignored only)
    if git diff --cached --quiet; then
      echo "nothing to commit (only ignored/untracked skipped?)"
      return 0
    fi
    git commit -m "$message"
    echo "committed: $message"
  else
    echo "working tree clean — no new commit"
  fi
}

cmd_pre() {
  local step="$1"
  require_step "$step"
  git_ok
  local tag="opt/pre-${step}"
  if git rev-parse "$tag" >/dev/null 2>&1; then
    echo "tag $tag already exists → $(git rev-parse --short "$tag")"
    echo "skipping pre-commit (checkpoint already taken)"
    return 0
  fi
  commit_if_dirty "chore(opt): checkpoint before ${step}"
  git tag -a "$tag" -m "OPT_PERF checkpoint before ${step}"
  echo "created tag $tag → $(git rev-parse --short HEAD)"
  push_all "$tag"
  echo "PRE-CHECK DONE: $tag"
}

cmd_post() {
  local step="$1"
  local detail="${2:-done}"
  require_step "$step"
  git_ok
  local tag="opt/${step}-done"
  if git rev-parse "$tag" >/dev/null 2>&1; then
    die "tag $tag already exists — refuse to overwrite. Delete manually if intentional."
  fi
  commit_if_dirty "feat(opt): ${step} — ${detail}"
  git tag -a "$tag" -m "OPT_PERF ${step} approved: ${detail}"
  echo "created tag $tag → $(git rev-parse --short HEAD)"
  push_all "$tag"
  echo "POST-CHECK DONE: $tag"
}

cmd_list() {
  git_ok
  echo "=== opt/* tags ==="
  git tag -l 'opt/*' --sort=creatordate
  echo "=== recent commits ==="
  git log --oneline --decorate -15
}

cmd_rollback() {
  local kind="$1"
  local step="$2"
  require_step "$step"
  git_ok
  local tag
  case "$kind" in
    pre) tag="opt/pre-${step}" ;;
    post|done) tag="opt/${step}-done" ;;
    *) die "rollback kind must be pre|post, got: $kind" ;;
  esac
  git rev-parse "$tag" >/dev/null 2>&1 || die "missing tag $tag"
  echo "WARNING: hard reset to $tag ($(git rev-parse --short "$tag"))"
  echo "Uncommitted work will be lost. Press Ctrl+C within 3s to abort..."
  sleep 3
  git reset --hard "$tag"
  echo "reset to $tag"
}

usage() {
  cat <<'EOF'
Usage:
  ./script/opt_checkpoint.sh pre <K0..K8>
  ./script/opt_checkpoint.sh post <K0..K8> [description]
  ./script/opt_checkpoint.sh list
  ./script/opt_checkpoint.sh rollback pre|post <K0..K8>
EOF
}

main() {
  local action="${1:-}"
  shift || true
  case "$action" in
    pre) cmd_pre "${1:-}" ;;
    post) cmd_post "${1:-}" "${2:-done}" ;;
    list) cmd_list ;;
    rollback) cmd_rollback "${1:-}" "${2:-}" ;;
    -h|--help|help|"") usage; exit 0 ;;
    *) die "unknown action: $action" ;;
  esac
}

main "$@"
