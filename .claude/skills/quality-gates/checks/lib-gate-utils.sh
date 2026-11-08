#!/usr/bin/env bash
# lib-gate-utils.sh — Shared utilities sourced by all gate check scripts.
# Provides: resolve_base_sha, read_config_value, read_config_array,
#           print_status, check_tool_installed

readonly _GATE_CONFIG=".quality-gates/config.yaml"

# Load .env overrides (safe parser, no clobber, allowed prefixes only)
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-env-loader.sh
source "$_LIB_DIR/lib-env-loader.sh"

# _has_mikefarah_yq — true only for mikefarah/yq. The pip package of the same name
# (kislyuk/yq) has a different CLI, so it must not be used for `yq e`.
# Checks never install anything: without it the grep/awk fallback is used.
_has_mikefarah_yq() {
  command -v yq &>/dev/null && yq --version 2>&1 | grep -qi 'mikefarah'
}

# resolve_run_mode — auto-detect execution context.
# Returns: pre-commit | pre-push | pr | ci | diff | full
# Override: QUALITY_GATES_MODE env var
resolve_run_mode() {
  # Explicit override
  [ -n "${QUALITY_GATES_MODE:-}" ] && echo "$QUALITY_GATES_MODE" && return

  # CI + PR context (GitHub Actions)
  if [ -n "${GITHUB_ACTIONS:-}" ] && [ -n "${GITHUB_BASE_REF:-}" ]; then
    echo "pr"; return
  fi
  # CI + PR context (GitLab CI)
  if [ -n "${GITLAB_CI:-}" ] && [ -n "${CI_MERGE_REQUEST_IID:-}" ]; then
    echo "pr"; return
  fi
  # Generic CI (no PR)
  [ -n "${CI:-}" ] && echo "ci" && return

  # Git hook scopes (set by hook scripts)
  [ "${QUALITY_GATES_SCOPE:-}" = "pre-commit" ] && echo "pre-commit" && return
  [ "${QUALITY_GATES_SCOPE:-}" = "pre-push" ]   && echo "pre-push"   && return

  # Local default — diff against main
  echo "diff"
}

# resolve_base_sha — resolve baseline commit SHA using run mode context.
# Prints SHA or empty string (empty = full scan).
resolve_base_sha() {
  # Explicit override always wins
  if [ -n "${BASE_SHA:-}" ]; then
    echo "$BASE_SHA"
    return
  fi

  local mode
  mode="$(resolve_run_mode)"

  case "$mode" in
    pre-commit)
      # Staged files approach — no commit baseline needed
      echo ""
      ;;
    pre-push)
      # Changes since upstream tracking branch
      git rev-parse "@{upstream}" 2>/dev/null \
        || git merge-base HEAD origin/main 2>/dev/null \
        || echo ""
      ;;
    pr)
      # PR base branch from CI env
      local base_branch="${GITHUB_BASE_REF:-${CI_MERGE_REQUEST_TARGET_BRANCH_NAME:-main}}"
      git merge-base HEAD "origin/${base_branch}" 2>/dev/null || echo ""
      ;;
    diff)
      # Local dev: diff against main/master
      for branch in origin/main origin/master; do
        if git rev-parse --verify "$branch" &>/dev/null; then
          git merge-base HEAD "$branch" 2>/dev/null && return
        fi
      done
      echo ""
      ;;
    full|ci|*)
      # Full scan — no baseline
      echo ""
      ;;
  esac
}

# read_config_value — read a scalar value from config.yaml by dotted key path.
# Usage: read_config_value "thresholds.coverage"
# Prints value or empty string if not found.
read_config_value() {
  local key="$1"
  local field
  field="$(basename "${key//.//}")"

  if _has_mikefarah_yq && [ -f "$_GATE_CONFIG" ]; then
    yq e ".${key}" "$_GATE_CONFIG" 2>/dev/null | grep -v '^null$'
  elif [ -f "$_GATE_CONFIG" ]; then
    # grep fallback — for dotted paths with 2+ segments, find parent key block first
    local parts depth parent
    IFS='.' read -ra parts <<< "$key"
    depth="${#parts[@]}"
    if [ "$depth" -ge 2 ]; then
      # Find the parent key and extract value from the 3-line context after it
      parent="${parts[$((depth - 2))]}"
      grep -A5 "^\s*${parent}:" "$_GATE_CONFIG" 2>/dev/null \
        | grep -E "^\s*${field}:\s*" | head -1 \
        | sed 's/[^:]*://' | sed 's/^\s*//' | sed 's/\s*#.*//' | tr -d '"' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
    else
      grep -E "^\s*${field}:\s*" "$_GATE_CONFIG" | head -1 \
        | sed 's/[^:]*://' | sed 's/^\s*//' | sed 's/\s*#.*//' | tr -d '"' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
    fi
  fi
}

# read_config_array — read a YAML list field as newline-separated values.
# Usage: read_config_array "trivy.severity"
# Prints one value per line, or empty if not found.
read_config_array() {
  local key="$1"
  local field
  field="$(basename "${key//.//}")"

  if _has_mikefarah_yq && [ -f "$_GATE_CONFIG" ]; then
    yq e ".${key}[]" "$_GATE_CONFIG" 2>/dev/null | grep -v '^null$'
  elif [ -f "$_GATE_CONFIG" ]; then
    # grep fallback: extract inline array [a, b, c] or multiline list items
    # Use awk with -v to safely pass field name; indent-aware block extraction
    # that stops at the next YAML key at same or lesser indentation.
    local raw
    raw="$(awk -v field="$field" '
      $0 ~ ("^[[:space:]]*" field ":") {
        found = 1
        # Count leading spaces (POSIX: no match() shorthand, use gsub trick)
        tmp = $0; gsub(/[^ \t].*/, "", tmp); indent = length(tmp)
        print; next
      }
      found {
        # Skip blank lines without exiting
        if ($0 ~ /^[[:space:]]*$/) { print; next }
        # Count leading spaces of current line
        tmp = $0; gsub(/[^ \t].*/, "", tmp); cur = length(tmp)
        # Stop when we hit a YAML key at same or lesser indent level
        if ($0 ~ /^[[:space:]]*[a-zA-Z_-]+:/ && cur <= indent) { exit }
        print
      }
    ' "$_GATE_CONFIG" 2>/dev/null | head -30)"
    # Try inline array: field: [a, b, c]
    local inline
    inline="$(echo "$raw" | head -1 | grep -oE '\[.*\]' | tr -d '[]' | tr ',' '\n' | sed "s/^[[:space:]]*//;s/[[:space:]]*$//;s/^['\"]//;s/['\"]$//")"
    if [ -n "$inline" ]; then
      echo "$inline"
    else
      # Multiline list: lines starting with "  - value", strip leading whitespace/dash and quotes
      echo "$raw" | grep -E '^[[:space:]]+-[[:space:]]' | sed "s/^[[:space:]]*-[[:space:]]*//;s/^['\"]//;s/['\"]$//"
    fi
  fi
}

# print_status — emit structured gate output line.
# Usage: print_status <gate> <ok|warn|error|skip|info> <message>
print_status() {
  local gate="$1"
  local level="$2"
  local msg="$3"
  local icon
  case "$level" in
    ok)    icon="✅" ;;
    warn)  icon="⚠️ " ;;
    error) icon="❌" ;;
    skip)  icon="ℹ️ " ;;
    info)  icon="ℹ️ " ;;
    *)     icon="   " ;;
  esac
  printf '[%-10s] %s %s\n' "$gate" "$icon" "$msg"
}

# _os_install_hint — return OS-appropriate install command for a known tool.
# Usage: _os_install_hint <tool>
_os_install_hint() {
  local tool="$1"
  local os
  os="$(uname -s 2>/dev/null)"

  case "$tool" in
    gitleaks)
      case "$os" in
        Darwin)  echo "brew install gitleaks" ;;
        Linux)   echo "apt-get install -y gitleaks  # or: go install github.com/gitleaks/gitleaks/v8@latest" ;;
        *)       echo "https://github.com/gitleaks/gitleaks/releases" ;;
      esac ;;
    semgrep)
      case "$os" in
        Darwin)  echo "brew install semgrep" ;;
        Linux)   echo "pip install semgrep  # or: pipx install semgrep" ;;
        *)       echo "https://github.com/semgrep/semgrep" ;;
      esac ;;
    trivy)
      case "$os" in
        Darwin)  echo "brew install trivy" ;;
        Linux)   echo "apt-get install -y trivy  # or: curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh" ;;
        *)       echo "https://github.com/aquasecurity/trivy/releases" ;;
      esac ;;
    nuclei)
      # nuclei is Go-based — go install works everywhere; brew only on macOS
      case "$os" in
        Darwin)  echo "brew install nuclei  # or: go install github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest" ;;
        *)       echo "go install github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest" ;;
      esac ;;
    sonar-scanner)
      case "$os" in
        Darwin)  echo "brew install sonar-scanner" ;;
        Linux)   echo "https://docs.sonarqube.org/latest/analyzing-source-code/scanners/sonarscanner/" ;;
        *)       echo "https://docs.sonarqube.org/latest/analyzing-source-code/scanners/sonarscanner/" ;;
      esac ;;
    tokei)
      case "$os" in
        Darwin)  echo "brew install tokei" ;;
        Linux)   echo "cargo install tokei  # or: snap install tokei" ;;
        *)       echo "cargo install tokei" ;;
      esac ;;
    yq)
      case "$os" in
        Darwin)  echo "brew install yq" ;;
        Linux)   echo "snap install yq  # or: https://github.com/mikefarah/yq#install" ;;
        *)       echo "https://github.com/mikefarah/yq#install" ;;
      esac ;;
    jq)
      case "$os" in
        Darwin)  echo "brew install jq" ;;
        Linux)   echo "apt-get install -y jq" ;;
        *)       echo "https://jqlang.github.io/jq/download/" ;;
      esac ;;
    *)
      echo "see documentation for install instructions" ;;
  esac
}

# check_tool_installed — check if a tool is in PATH.
# Usage: check_tool_installed <tool>  (hint auto-resolved by OS)
# Returns 0 if installed, exits 3 with message if not.
check_tool_installed() {
  local tool="$1"
  if ! command -v "$tool" &>/dev/null; then
    local hint
    hint="$(_os_install_hint "$tool")"
    print_status "$tool" "skip" "not installed → ${hint}"
    exit 3
  fi
}
