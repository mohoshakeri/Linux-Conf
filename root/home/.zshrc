export ZSH="$HOME/.oh-my-zsh"


ZSH_THEME="agnoster"

plugins=(git zsh-syntax-highlighting zsh-autosuggestions)

source $ZSH/oh-my-zsh.sh

echo "Hello"

alias "vpn"="nohup sudo hiddify"

# Auto Alias Scripts From ~/scripts
if [ -d "/home/mohosh/Documents/Programming/MyLinux/scripts" ]; then
  for script in "/home/mohosh/Documents/Programming/MyLinux/scripts"/*; do
	script_name=$(basename "$script")
	alias_name="${script_name%.*}"
	alias "$alias_name"="bash $script"
	
	echo "$alias_name Registered"
  done
fi
