#!/bin/bash

REQUIRED_CMDS=(wofi jq hyprctl)
for cmd in "${REQUIRED_CMDS[@]}"; do
  command -v "$cmd" &>/dev/null || { echo "Missing required command: $cmd"; exit 1; }
done

DEPLOY_DIR="$HOME/.local/share/hypr-deploy"
AUTOSTART_FILE="$HOME/.config/hypr/autostart.conf"
ZSHRC_FILE="$HOME/.zshrc"
MASTER_DEPLOY_SCRIPT="$DEPLOY_DIR/deploy_master.sh"
mkdir -p "$DEPLOY_DIR"

is_tty() { [[ -t 0 && -t 1 ]]; }

launcher_prompt() {
  local prompt="$1"; shift
  printf "%s\n" "$@" | wofi --dmenu -p "$prompt"
}

prompt_capture_scope() {
  local options=("All Workspaces" "One Workspace")
  if is_tty; then
    echo "Capture which scope?"
    select opt in "${options[@]}"; do
      [[ " ${options[*]} " == *" $opt "* ]] && echo "$opt" && return
    done
  else
    launcher_prompt "Capture Scope" "${options[@]}"
  fi
}

get_workspaces() {
  hyprctl workspaces -j | jq -r '.[].id' | sort -n
}

capture_all_workspaces() {
  hyprctl clients -j
}

capture_one_workspace() {
  local ws_id="$1"
  hyprctl clients -j | jq -c --arg ws "$ws_id" '.[] | select(.workspace.id == ($ws|tonumber))'
}

get_window_command_and_cwd() {
  local json="$1"
  local pid class ws_id cmdline cwd exec_cmd resolved

  pid=$(jq -r '.pid' <<< "$json")
  class=$(jq -r '.class' <<< "$json")
  ws_id=$(jq -r '.workspace.id' <<< "$json")

  [[ ! -d "/proc/$pid" ]] && return

  # Read the full command line of the process
  cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" | sed 's/ *$//')

  # Ignore empty or shell commands (adjust as needed)
  [[ -z "$cmdline" || "$cmdline" =~ ^(bash|zsh|sh)$ ]] && return

  declare -A terminals=(
    [Alacritty]=1 [foot]=1 [kitty]=1 [wezterm]=1
    [wezterm-gui]=1 [gnome-terminal]=1 [xfce4-terminal]=1
    [terminator]=1 [xterm]=1
  )

  # If terminal emulator, get current working directory of process
  cwd=""
  [[ ${terminals[$class]} ]] && cwd=$(readlink -f "/proc/$pid/cwd")

  # Normalize command: resolve executable path if possible
  exec_cmd="${cmdline%% *}"
  if [[ "$exec_cmd" != /* ]]; then
    resolved=$(command -v "$exec_cmd" 2>/dev/null)
    [[ -n "$resolved" ]] && cmdline="$resolved${cmdline#$exec_cmd}"
  fi

  printf "%s|%s|%s\n" "$ws_id" "$cmdline" "$cwd"
}

generate_deploy_script() {
  local script="$1"; shift
  local -a winlist=("$@")

  {
    echo "#!/bin/bash"
    echo "# Auto-generated deployment script"
    echo ""

    declare -A ws_map
    for win in "${winlist[@]}"; do
      ws="${win%%|*}"
      ws_map["$ws"]+="$win"$'\n'
    done

    for ws in "${!ws_map[@]}"; do
      echo "echo 'Switching to workspace $ws'"
      echo "hyprctl dispatch workspace $ws"
      echo "sleep 0.3"

      while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        ws_id="${line%%|*}"
        rest="${line#*|}"
        cmd="${rest%%|*}"
        cwd="${rest#*|}"

        # Safely quote command and cwd for shell
        quoted_cmd=$(printf '%q' "$cmd")

        if [[ -n "$cwd" && "$cwd" != "." ]]; then
          quoted_cwd=$(printf '%q' "$cwd")
          echo "echo 'Launching in $cwd: $cmd'"
          echo "(cd $quoted_cwd && $quoted_cmd &) || echo 'Failed to launch: $cmd'"
        else
          echo "echo 'Launching: $cmd'"
          echo "$quoted_cmd &"
        fi
      done <<< "${ws_map[$ws]}"
      echo ""
    done
  } > "$script"

  chmod +x "$script"
  echo "Deployment script saved to: $script"
}

prompt_master_script_update_mode() {
  local options=("Append (add new script call)" "Clean (overwrite with new script call)")
  if is_tty; then
    echo "Update master deploy script?"
    select opt in "${options[@]}"; do
      [[ " ${options[*]} " == *" $opt "* ]] && echo "$opt" && return
    done
  else
    launcher_prompt "Update master script mode" "${options[@]}"
  fi
}

add_script_to_master() {
  local new="$1"
  local mode
  mode=$(prompt_master_script_update_mode)
  if [[ "$mode" == "Clean (overwrite with new script call)" ]]; then
    echo -e "#!/bin/bash\n# Master deployment script\n" > "$MASTER_DEPLOY_SCRIPT"
  fi
  echo "bash \"$new\" &" >> "$MASTER_DEPLOY_SCRIPT"
  chmod +x "$MASTER_DEPLOY_SCRIPT"
  echo "Updated master script: $MASTER_DEPLOY_SCRIPT"
}

ask_autostart_add() {
  if is_tty; then
    read -rp "Add master script to Hyprland autostart? [y/N] " yn
    [[ "$yn" =~ ^[Yy]$ ]]
  else
    [[ $(launcher_prompt "Add to autostart?" "Yes" "No") == "Yes" ]]
  fi
}

add_to_autostart() {
  local line="exec = $MASTER_DEPLOY_SCRIPT"
  grep -Fxq "$line" "$AUTOSTART_FILE" || {
    echo "$line" >> "$AUTOSTART_FILE"
    echo "Added to Hyprland autostart."
  }
}

ask_add_alias() {
  if is_tty; then
    read -rp "Add ZSH alias for this script? [y/N] " yn
    [[ "$yn" =~ ^[Yy]$ ]]
  else
    [[ $(launcher_prompt "Add ZSH alias?" "Yes" "No") == "Yes" ]]
  fi
}

prompt_alias_name() {
  if is_tty; then
    read -rp "Enter alias name: " name
  else
    name=""
    while [[ -z "$name" ]]; do
      name=$(launcher_prompt "Enter alias name")
    done
  fi
  echo "$name"
}

add_zsh_alias() {
  local name="$1"
  local target="$2"
  local line="alias $name='$target'"
  grep -Fxq "$line" "$ZSHRC_FILE" || {
    echo "$line" >> "$ZSHRC_FILE"
    echo "Alias '$name' added to ZSH config."
  }
}

# Entry point
echo "Hyprland App Snapshot Utility"
choice=$(prompt_capture_scope)
windows=()

if [[ "$choice" == "All Workspaces" ]]; then
  clients=$(capture_all_workspaces)
  mapfile -t windows < <(jq -c '.[]' <<< "$clients" | while read -r c; do get_window_command_and_cwd "$c"; done)
else
  ws_ids=($(get_workspaces))
  if is_tty; then
    echo "Select workspace:"
    select ws_id in "${ws_ids[@]}"; do
      [[ " ${ws_ids[*]} " == *" $ws_id "* ]] && break
    done
  else
    ws_id=$(launcher_prompt "Select Workspace" "${ws_ids[@]}")
  fi
  clients=$(capture_one_workspace "$ws_id")
  mapfile -t windows < <(jq -c '.' <<< "$clients" | while read -r c; do get_window_command_and_cwd "$c"; done)
fi

[[ ${#windows[@]} -eq 0 ]] && { echo "No windows captured."; exit 1; }

timestamp=$(date +%Y%m%d_%H%M%S)
script_path="$DEPLOY_DIR/deploy_$timestamp.sh"
generate_deploy_script "$script_path" "${windows[@]}"

if ask_autostart_add; then
  add_script_to_master "$script_path"
  add_to_autostart
fi

if ask_add_alias; then
  alias_name=$(prompt_alias_name)
  add_zsh_alias "$alias_name" "$script_path"
fi

echo "Ready to deploy!"
