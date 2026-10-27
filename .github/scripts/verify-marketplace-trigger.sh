#!/usr/bin/env bash
#
# Offline check of the Azure Marketplace workflow's trigger logic.
#
# We have no runners yet, so this replays the parts of
# .github/workflows/azure-marketplace-release.yaml that decide whether a run
# starts and which version it would publish, and prints the verdict instead of
# doing anything. Nothing is pushed, built or published.
#
# It reads the tag filter and the chart paths OUT of the workflow file rather
# than hardcoding them, so editing the workflow cannot silently leave this
# script testing something else.
#
#   ./verify-marketplace-trigger.sh                      # newest release tag
#   ./verify-marketplace-trigger.sh <tag>                # simulate pushing <tag>
#   ./verify-marketplace-trigger.sh --all                # replay every tag in the repo
#   ./verify-marketplace-trigger.sh --dispatch <ref> [tag]   # simulate workflow_dispatch
#
# Exit status: 0 = a run would start and reach the build, 1 = it would not.

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$REPO_ROOT"
WORKFLOW=".github/workflows/azure-marketplace-release.yaml"

if [[ ! -f "$WORKFLOW" ]]; then
  echo "error: $WORKFLOW not found (run this from inside the repo)" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Read the workflow's own configuration.
# ---------------------------------------------------------------------------

# on: -> push: -> tags: -> the list of glob patterns
TAG_PATTERNS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && TAG_PATTERNS[${#TAG_PATTERNS[@]}]="$line"
done < <(awk '
  /^on:/                  { inon = 1; next }
  inon && /^[a-zA-Z]/     { inon = 0 }
  inon && /^  push:/      { inpush = 1; next }
  inon && inpush && /^  [a-zA-Z]/ { inpush = 0 }
  inpush && /^    tags:/  { intags = 1; next }
  intags && /^    [a-zA-Z]/ { intags = 0 }
  intags && /^ *- /       { sub(/^ *- */, ""); gsub(/^['"'"'"]|['"'"'"]$/, ""); print }
' "$WORKFLOW")

# Top-level env: block (2-space indent; job-level envs are deeper).
read_env() {
  grep -E "^  $1:" "$WORKFLOW" | head -1 | sed -E "s/^  $1:[[:space:]]*//" | tr -d '"'
}
CHART_NAME=$(read_env CHART_NAME)
CHART_SRC=$(read_env CHART_SRC)
AZURE_DIR=$(read_env AZURE_DIR)

if [[ ${#TAG_PATTERNS[@]} -eq 0 || -z "$CHART_NAME" || -z "$CHART_SRC" || -z "$AZURE_DIR" ]]; then
  echo "error: could not read the trigger config out of $WORKFLOW" >&2
  echo "       patterns=${#TAG_PATTERNS[@]} CHART_NAME='$CHART_NAME' CHART_SRC='$CHART_SRC' AZURE_DIR='$AZURE_DIR'" >&2
  echo "       the workflow's shape changed - update this script to match." >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# The three checks the workflow applies, in order.
# ---------------------------------------------------------------------------

# 1. GitHub's on.push.tags filter. Its `*` does not cross a `/`, unlike bash's.
tag_matches_filter() {
  local tag="$1" pat
  for pat in "${TAG_PATTERNS[@]}"; do
    if [[ "$pat" != */* && "$tag" == */* ]]; then
      continue # a `/`-free pattern can never match a `/`-bearing tag
    fi
    # shellcheck disable=SC2053 -- intentional glob match, not a literal compare
    if [[ "$tag" == $pat ]]; then
      MATCHED_PATTERN="$pat"
      return 0
    fi
  done
  return 1
}

# 2. "Resolve release version": strip the chart prefix, demand x.y.z.
tag_to_version() {
  printf '%s' "${1#${CHART_NAME}-}"
}

# 3. The tagged tree must agree with the version in the tag.
chart_version_at() {
  local ref="$1"
  if [[ "$ref" == "WORKTREE" ]]; then
    grep -E '^version:' "${CHART_SRC}/Chart.yaml" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"'
  else
    git show "${ref}:${CHART_SRC}/Chart.yaml" 2>/dev/null | head -40 \
      | grep -E '^version:' | head -1 | awk '{print $2}' | tr -d '"'
  fi
}

# Informational only: what build-bundle checks right after the version gate.
missing_azure_files() {
  local ref="$1" f missing=""
  for f in manifest.yaml mainTemplate.json createUIDefinition.json README.md; do
    if [[ "$ref" == "WORKTREE" ]]; then
      [[ -f "${AZURE_DIR}/${f}" ]] || missing="${missing}${f} "
    else
      git cat-file -e "${ref}:${AZURE_DIR}/${f}" 2>/dev/null || missing="${missing}${f} "
    fi
  done
  printf '%s' "$missing"
}

# ---------------------------------------------------------------------------
# One simulation.
#   $1 = the tag as GitHub would see it (github.ref_name, or the `tag` input)
#   $2 = the ref the job would check out
#   $3 = "quiet" for one-line output
# ---------------------------------------------------------------------------
simulate() {
  local raw="$1" ref="$2" mode="${3:-verbose}" event="${4:-push}"
  local version chart_ver missing

  if [[ "$mode" == "quiet" ]]; then
    if ! tag_matches_filter "$raw"; then
      printf '  %-46s  ignored by filter\n' "$raw"; return 1
    fi
    version=$(tag_to_version "$raw")
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      printf '  %-46s  STARTS then FAILS (not x.y.z)\n' "$raw"; return 1
    fi
    chart_ver=$(chart_version_at "$ref")
    if [[ "$chart_ver" != "$version" ]]; then
      printf '  %-46s  STARTS then FAILS (Chart.yaml=%s)\n' "$raw" "${chart_ver:-none}"; return 1
    fi
    printf '  %-46s  TRIGGER -> publish %s\n' "$raw" "$version"; return 0
  fi

  echo "tag being simulated : $raw"
  echo "checkout ref        : $ref"
  echo

  # --- 1 -------------------------------------------------------------------
  # workflow_dispatch does NOT consult on.push.tags - a manual run always
  # starts, whatever ref you pick, and only then hits the version gate.
  if [[ "$event" == "dispatch" ]]; then
    printf '  [1/3] on.push.tags filter    N/A    workflow_dispatch ignores it; the run always starts\n'
  elif tag_matches_filter "$raw"; then
    printf '  [1/3] on.push.tags filter    PASS   matched %s\n' "'$MATCHED_PATTERN'"
  else
    printf '  [1/3] on.push.tags filter    FAIL   matches none of: %s\n' "${TAG_PATTERNS[*]}"
    echo
    echo "  => NO RUN WOULD START. GitHub never queues the workflow."
    return 1
  fi

  # --- 2 -------------------------------------------------------------------
  version=$(tag_to_version "$raw")
  if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '  [2/3] tag -> version         PASS   %s\n' "$version"
  else
    printf '  [2/3] tag -> version         FAIL   %s is not x.y.z\n' "'$version'"
    echo
    echo "  => A RUN WOULD START and then fail at 'Resolve release version'."
    return 1
  fi

  # --- 3 -------------------------------------------------------------------
  chart_ver=$(chart_version_at "$ref")
  if [[ -z "$chart_ver" ]]; then
    printf '  [3/3] Chart.yaml agrees      FAIL   no %s/Chart.yaml at %s\n' "$CHART_SRC" "$ref"
    echo
    echo "  => A RUN WOULD START and then fail at 'Resolve release version'."
    return 1
  elif [[ "$chart_ver" != "$version" ]]; then
    printf '  [3/3] Chart.yaml agrees      FAIL   tag says %s, Chart.yaml at this ref says %s\n' "$version" "$chart_ver"
    echo
    echo "  => A RUN WOULD START and then fail at 'Resolve release version'."
    echo "     (wrong commit tagged, or dispatched from a branch instead of the tag)"
    return 1
  fi
  printf '  [3/3] Chart.yaml agrees      PASS   %s\n' "$chart_ver"

  echo
  echo "  => WORKFLOW WOULD TRIGGER  -  publish chart ${version} to the Marketplace plan"
  echo

  # Not a trigger condition, but it is the very next thing that runs.
  missing=$(missing_azure_files "$ref")
  if [[ -n "$missing" ]]; then
    echo "  NOTE: 'Verify expected repo layout' would then fail - missing in ${AZURE_DIR}/:"
    echo "        ${missing}"
  else
    echo "  'Verify expected repo layout' would pass: all 4 ${AZURE_DIR}/ files present."
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
echo "workflow   : $WORKFLOW"
echo "tag filter : ${TAG_PATTERNS[*]}"
echo "chart      : $CHART_NAME  ($CHART_SRC)"
echo "-----------------------------------------------------------------------"

case "${1:-}" in
  -h|--help)
    sed -n '3,21p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;

  --all)
    echo "Replaying every tag in the repo, each against its own commit:"
    echo
    trig=0; ign=0; brk=0
    while IFS= read -r t; do
      if simulate "$t" "$t" quiet; then
        trig=$((trig + 1))
      elif tag_matches_filter "$t"; then
        brk=$((brk + 1))
      else
        ign=$((ign + 1))
      fi
    done < <(git tag | sort -V)
    echo
    echo "-----------------------------------------------------------------------"
    echo "would trigger: $trig    would start then fail: $brk    ignored by filter: $ign"
    [[ $brk -eq 0 ]] || exit 1
    ;;

  --dispatch)
    ref="${2:-}"
    if [[ -z "$ref" ]]; then echo "error: --dispatch needs a ref" >&2; exit 2; fi
    # workflow_dispatch checks out the ref you select; the `tag` input only
    # changes the version, never the checkout. That gap is the usual mistake.
    raw="${3:-$ref}"
    echo "simulating: workflow_dispatch (ref=$ref, tag input=${3:-<none>})"
    echo
    simulate "$raw" "$ref" verbose dispatch
    ;;

  "")
    latest=$(git tag --list "${CHART_NAME}-*" | sort -V | tail -1)
    if [[ -z "$latest" ]]; then echo "no ${CHART_NAME}-* tags in this repo" >&2; exit 2; fi
    echo "no tag given - using the newest release tag"
    echo
    simulate "$latest" "$latest"
    ;;

  *)
    tag="$1"
    # If the tag exists, read Chart.yaml from its commit, as the runner would.
    if git rev-parse -q --verify "refs/tags/${tag}" >/dev/null; then
      simulate "$tag" "$tag"
    else
      echo "note: '$tag' is not an existing tag - checking against the working tree,"
      echo "      which is what you would get by tagging HEAD right now."
      echo
      simulate "$tag" "WORKTREE"
    fi
    ;;
esac
