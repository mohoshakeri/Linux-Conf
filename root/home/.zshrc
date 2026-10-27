export ZSH="$HOME/.oh-my-zsh"


ZSH_THEME="agnoster"

plugins=(git zsh-syntax-highlighting zsh-autosuggestions)

source $ZSH/oh-my-zsh.sh

echo "Hello"

# Run Conf Scripts In The Current Shell So They Can Request cd / open / eval
_run_conf_script() {
  local script="$1"
  shift
  local tmp exit_code=0 line
  tmp="$(mktemp)" || return 1
  bash "$script" "$@" >"$tmp"
  exit_code=$?
  if (( exit_code == 0 )); then
    while IFS= read -r line || [[ -n "$line" ]]; do
      case "$line" in
        __SHELL__:cd:*)
          cd -- "${line#__SHELL__:cd:}" || { rm -f "$tmp"; return 1; }
          ;;
        __SHELL__:open:*)
          (xdg-open "${line#__SHELL__:open:}" >/dev/null 2>&1 &)
          ;;
        __SHELL__:eval:*)
          eval "${line#__SHELL__:eval:}"
          ;;
        '')
          ;;
        *)
          # Ignore Stray Ansi / Ui Leak Lines; Keep Plain Text Feedback
          if [[ "$line" != *$'\e'* && "$line" != Projects\ * && "$line" != Showing\ * ]]; then
            print -r -- "$line"
          fi
          ;;
      esac
    done <"$tmp"
  else
    while IFS= read -r line || [[ -n "$line" ]]; do
      case "$line" in
        __SHELL__:*) ;;
        *) print -r -- "$line" ;;
      esac
    done <"$tmp"
  fi
  rm -f "$tmp"
  return $exit_code
}

# Auto Register Scripts As Shell Functions
if [ -d "/home/mohosh/Documents/Programming/Linux-Conf/scripts" ]; then
  for script in "/home/mohosh/Documents/Programming/Linux-Conf/scripts"/*; do
	[[ -f "$script" ]] || continue
	script_name=$(basename "$script")
	alias_name="${script_name%.*}"
	eval "function ${alias_name}() { _run_conf_script ${(q)script} \"\$@\"; }"
	echo "$alias_name Registered"
  done
fi

# Setup VPN
alias vpn='sudo -v && sudo env V2RAY_CONFIG=XXXXX bash /home/mohosh/Documents/Programming/Linux-Conf/scripts/v2ray-tunnel.sh'
