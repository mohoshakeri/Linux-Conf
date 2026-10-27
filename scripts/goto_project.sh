#!/bin/bash

# Interactive Git Project Picker Under ~/Documents/Programming
# Ui Goes To The Terminal; Shell Directives Go To Real Stdout (Fd 3)

ROOT="${GOTO_PROJECT_ROOT:-$HOME/Documents/Programming}"
SKIP_DIRS=("node_modules" "__pycache__" ".venv" "venv" "dist" "build" ".cache" ".tox" ".mypy_cache" ".pytest_cache" ".idea" ".vscode")

declare -a PROJECT_PATHS=()
declare -a PROJECT_LABELS=()

TERM_ROWS=24
TERM_COLS=80

is_skipped_dir() {
  local name="$1"
  local skip
  for skip in "${SKIP_DIRS[@]}"; do
    [[ "$name" == "$skip" ]] && return 0
  done
  return 1
}

# Collect Git Roots; Stop Descending When .git Is Found
scan_projects() {
  local dir="$1"
  local child name

  while IFS= read -r -d '' child; do
    name="$(basename "$child")"

    [[ "$name" == .* ]] && continue
    is_skipped_dir "$name" && continue

    if [[ -e "$child/.git" ]]; then
      PROJECT_PATHS+=("$child")
      PROJECT_LABELS+=("${child#$ROOT/}")
      continue
    fi

    scan_projects "$child"
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)
}

refresh_term_size() {
  local rows cols
  if IFS=' ' read -r rows cols < <(stty size 2>/dev/null); then
    if [[ "$rows" =~ ^[1-9][0-9]*$ ]] && ((rows >= 8 && rows <= 200)); then
      TERM_ROWS="$rows"
    fi
    if [[ "$cols" =~ ^[1-9][0-9]*$ ]] && ((cols >= 40 && cols <= 500)); then
      TERM_COLS="$cols"
    fi
  fi
}

# Build One Frame And Print Once (Avoids Flicker From Clear + Many Writes)
draw_ui() {
  local selected="$1"
  local offset="$2"
  local visible="$3"
  local total="${#PROJECT_PATHS[@]}"
  local end=$((offset + visible - 1))
  local width=$((TERM_COLS - 4))
  local i label drawn=0
  local frame=""

  ((width < 10)) && width=10
  ((end >= total)) && end=$((total - 1))

  # Home Cursor Only — Do Not Full-Clear (That Causes Jump/Flicker)
  frame+=$'\033[H'
  frame+="Projects (${total})"$'\033[K\n'
  frame+="↑/↓ move   Enter cd   q cancel"$'\033[K\n'
  frame+="────────────────────────────────────────"$'\033[K\n'

  for ((i = offset; i <= end; i++)); do
    label="${PROJECT_LABELS[$i]}"
    if ((${#label} > width)); then
      label="${label:0:$((width - 1))}…"
    fi
    if [[ "$i" -eq "$selected" ]]; then
      frame+=$'\033[7m'" > ${label}"$'\033[0m\033[K\n'
    else
      frame+="   ${label}"$'\033[K\n'
    fi
    drawn=$((drawn + 1))
  done

  # Wipe Leftover Rows From A Previously Longer Viewport
  while ((drawn < visible)); do
    frame+=$'\033[K\n'
    drawn=$((drawn + 1))
  done

  frame+="────────────────────────────────────────"$'\033[K\n'
  frame+="$((offset + 1))-$((end + 1)) / ${total}"$'\033[K\n'
  # Clear Any Junk Below The Footer
  frame+=$'\033[J'

  printf '%s' "$frame"
}

read_key() {
  local key rest
  IFS= read -rsn1 key || return 1
  if [[ "$key" == $'\e' ]]; then
    IFS= read -rsn1 -t 0.05 rest || {
      printf '%s' "$key"
      return 0
    }
    key+="$rest"
    if [[ "$rest" == '[' || "$rest" == 'O' ]]; then
      while IFS= read -rsn1 -t 0.05 rest; do
        key+="$rest"
        [[ "$rest" =~ [A-Za-z~] ]] && break
      done
    fi
  fi
  printf '%s' "$key"
}

emit_selection() {
  local selected_path="$1"
  printf '__SHELL__:cd:%s\n' "$selected_path" >&3
  printf '%s\n' "$selected_path" >&3
}

run_tui() {
  local total="${#PROJECT_PATHS[@]}"
  local selected=0
  local offset=0
  local visible=0
  local max_offset=0
  local key selected_path

  if [[ "$total" -eq 0 ]]; then
    printf 'No git projects found under %s\n' "$ROOT" >&2
    return 1
  fi

  # Fd 3 = Caller Stdout; Stdout/Stdin Switch To The Real Terminal For Ui
  exec 3>&1
  exec >/dev/tty </dev/tty || {
    printf 'Interactive terminal required\n' >&2
    exec 3>&-
    return 1
  }

  refresh_term_size
  trap 'refresh_term_size' WINCH

  printf '\033[?1049h\033[?25l\033[H\033[2J'
  trap 'printf "\033[?25h\033[?1049l"; exec 3>&-' EXIT

  while true; do
    visible=$((TERM_ROWS - 5))
    ((visible < 3)) && visible=3
    ((visible > total)) && visible="$total"
    max_offset=$((total - visible))
    ((max_offset < 0)) && max_offset=0

    if ((selected < offset)); then
      offset="$selected"
    elif ((selected >= offset + visible)); then
      offset=$((selected - visible + 1))
    fi
    ((offset < 0)) && offset=0
    ((offset > max_offset)) && offset="$max_offset"

    draw_ui "$selected" "$offset" "$visible"
    key="$(read_key)" || return 1

    case "$key" in
      $'\e[A'|$'\eOA'|k)
        ((selected > 0)) && selected=$((selected - 1))
        ;;
      $'\e[B'|$'\eOB'|j)
        ((selected < total - 1)) && selected=$((selected + 1))
        ;;
      $'\e[5~'|$'\e[H'|$'\eOH'|g)
        selected=0
        ;;
      $'\e[6~')
        selected=$((selected + visible))
        ((selected > total - 1)) && selected=$((total - 1))
        ;;
      $'\e[F'|$'\eOF'|G)
        selected=$((total - 1))
        ;;
      ''|$'\n'|$'\r')
        selected_path="${PROJECT_PATHS[$selected]}"
        printf '\033[?25h\033[?1049l'
        trap 'exec 3>&-' EXIT
        emit_selection "$selected_path"
        return 0
        ;;
      q|Q|$'\e')
        printf '\033[?25h\033[?1049l'
        trap 'exec 3>&-' EXIT
        return 1
        ;;
    esac
  done
}

main() {
  if [[ ! -d "$ROOT" ]]; then
    printf 'Root directory not found: %s\n' "$ROOT" >&2
    exit 1
  fi

  scan_projects "$ROOT"

  if ! run_tui; then
    exit 1
  fi
}

main "$@"
