#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Codex"
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
AUTH_FILE="$CODEX_DIR/auth.json"
SWITCHER_DIR="$HOME/.codex-account-switcher"
PROFILES_DIR="$SWITCHER_DIR/profiles"
CURRENT_FILE="$SWITCHER_DIR/current_profile"
BACKUP_DIR="$SWITCHER_DIR/backups"
LOG_FILE="$SWITCHER_DIR/switcher.log"

umask 077
mkdir -p "$PROFILES_DIR" "$BACKUP_DIR"
chmod 700 "$SWITCHER_DIR" "$PROFILES_DIR" "$BACKUP_DIR" 2>/dev/null || true

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}

die() {
  log "ERROR: $*"
  osascript -e "display alert \"Codex Account Switcher\" message \"$(printf '%s' "$*" | sed 's/"/\\"/g')\" as critical" >/dev/null 2>&1 || true
  exit 1
}

notify() {
  osascript -e "display notification \"$(printf '%s' "$1" | sed 's/"/\\"/g')\" with title \"Codex Account Switcher\"" >/dev/null 2>&1 || true
}

profile_path() {
  local profile="$1"
  printf '%s/%s/auth.json' "$PROFILES_DIR" "$profile"
}

validate_profile_name() {
  local profile="${1:-}"
  [[ "$profile" =~ ^[A-Za-z0-9._-]+$ ]] || die "Имя профиля может содержать только латиницу, цифры, точку, дефис и подчёркивание."
}

require_auth() {
  [[ -f "$AUTH_FILE" ]] || die "Не найден $AUTH_FILE. Сначала войдите в Codex вручную."
}

save_current_to_named_profile() {
  local profile="$1"
  validate_profile_name "$profile"
  require_auth

  local dir="$PROFILES_DIR/$profile"
  mkdir -p "$dir"
  chmod 700 "$dir"
  cp -p "$AUTH_FILE" "$dir/auth.json"
  chmod 600 "$dir/auth.json"
  printf '%s\n' "$profile" > "$CURRENT_FILE"
  log "Saved current auth as profile '$profile'"
  notify "Текущий вход сохранён как профиль '$profile'."
}

save_current_to_active_profile_if_possible() {
  [[ -f "$AUTH_FILE" && -f "$CURRENT_FILE" ]] || return 0
  local current
  current="$(cat "$CURRENT_FILE" 2>/dev/null || true)"
  [[ -n "$current" && -f "$(profile_path "$current")" ]] || return 0
  cp -p "$AUTH_FILE" "$(profile_path "$current")"
  chmod 600 "$(profile_path "$current")"
  log "Refreshed active profile '$current'"
}

list_profiles() {
  find "$PROFILES_DIR" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null \
    | sed 's#.*/##' \
    | sort
}

quit_codex() {
  osascript <<'APPLESCRIPT' >/dev/null 2>&1 || true
tell application "System Events"
  if exists process "Codex" then
    tell application "Codex" to quit
  end if
end tell
APPLESCRIPT
  sleep 1
}

open_codex() {
  open -a "$APP_NAME" >/dev/null 2>&1 || true
}

switch_profile() {
  local profile="$1"
  validate_profile_name "$profile"
  local source
  source="$(profile_path "$profile")"
  [[ -f "$source" ]] || die "Профиль '$profile' не найден. Сначала сохраните его."
  mkdir -p "$CODEX_DIR"

  save_current_to_active_profile_if_possible

  if [[ -f "$AUTH_FILE" ]]; then
    cp -p "$AUTH_FILE" "$BACKUP_DIR/auth.$(date '+%Y%m%d-%H%M%S').json"
  fi

  quit_codex
  cp -p "$source" "$AUTH_FILE"
  chmod 600 "$AUTH_FILE"
  printf '%s\n' "$profile" > "$CURRENT_FILE"
  log "Switched to profile '$profile'"
  open_codex
  notify "Codex переключён на профиль '$profile'."
}

choose_profile() {
  local profiles profile
  profiles="$(list_profiles)"
  [[ -n "$profiles" ]] || die "Профилей пока нет. Запустите: scripts/codex-account-switcher.sh save your_name"

  profile="$(osascript <<APPLESCRIPT
set profileList to paragraphs of "$(printf '%s' "$profiles" | sed 's/\\/\\\\/g; s/"/\\"/g')"
set picked to choose from list profileList with title "Codex Account Switcher" with prompt "Выберите аккаунт Codex:" OK button name "Переключить" cancel button name "Отмена"
if picked is false then
  return ""
else
  return item 1 of picked
end if
APPLESCRIPT
)"
  [[ -n "$profile" ]] || exit 0
  switch_profile "$profile"
}

prompt_save_profile() {
  local default_name="${1:-me}"
  local profile
  profile="$(osascript <<APPLESCRIPT
set profileName to text returned of (display dialog "Введите короткое имя для текущего входа Codex:" default answer "$default_name" with title "Codex Account Switcher" buttons {"Отмена", "Сохранить"} default button "Сохранить" cancel button "Отмена")
return profileName
APPLESCRIPT
)"
  [[ -n "$profile" ]] || exit 0
  save_current_to_named_profile "$profile"
}

toggle_or_setup() {
  local profiles count current other
  profiles="$(list_profiles)"
  count="$(printf '%s\n' "$profiles" | sed '/^$/d' | wc -l | tr -d ' ')"

  if [[ "$count" == "0" ]]; then
    osascript -e 'display dialog "Сейчас я сохраню текущий вход Codex как первый профиль." with title "Codex Account Switcher" buttons {"Отмена", "Продолжить"} default button "Продолжить" cancel button "Отмена"' >/dev/null
    prompt_save_profile "me"
    exit 0
  fi

  if [[ "$count" == "1" ]]; then
    osascript -e 'display dialog "Сохранён только один профиль. Войдите в Codex под вторым аккаунтом вручную, затем снова запустите переключатель и сохраните второй профиль." with title "Codex Account Switcher" buttons {"Сохранить текущий вход", "OK"} default button "OK"' >/tmp/codex-switcher-dialog.$$ 2>/dev/null || exit 0
    if grep -q "Сохранить текущий вход" /tmp/codex-switcher-dialog.$$ 2>/dev/null; then
      rm -f /tmp/codex-switcher-dialog.$$
      prompt_save_profile "brother"
    fi
    rm -f /tmp/codex-switcher-dialog.$$
    exit 0
  fi

  if [[ "$count" == "2" && -f "$CURRENT_FILE" ]]; then
    current="$(cat "$CURRENT_FILE" 2>/dev/null || true)"
    other="$(printf '%s\n' "$profiles" | sed '/^$/d' | awk -v current="$current" '$0 != current { print; exit }')"
    if [[ -n "$other" ]]; then
      switch_profile "$other"
      exit 0
    fi
  fi

  choose_profile
}

show_status() {
  local current profiles
  current="$(cat "$CURRENT_FILE" 2>/dev/null || printf 'не выбран')"
  profiles="$(list_profiles | sed 's/^/• /' || true)"
  [[ -n "$profiles" ]] || profiles="Профилей пока нет."
  osascript -e "display dialog \"Активный профиль: $current\n\n$profiles\" with title \"Codex Account Switcher\" buttons {\"OK\"} default button \"OK\"" >/dev/null
}

usage() {
  cat <<'USAGE'
Usage:
  codex-account-switcher.sh run
  codex-account-switcher.sh choose
  codex-account-switcher.sh switch <profile>
  codex-account-switcher.sh save <profile>
  codex-account-switcher.sh list
  codex-account-switcher.sh status

First-time flow:
  1. Log into Codex manually as the first person.
  2. Run: ./scripts/codex-account-switcher.sh save your_name
  3. Log into Codex manually as the second person.
  4. Run: ./scripts/codex-account-switcher.sh save brother_name
  5. Open "Codex Account Switcher.app" and choose the account.
USAGE
}

command="${1:-run}"
case "$command" in
  run) toggle_or_setup ;;
  choose) choose_profile ;;
  switch) [[ $# -eq 2 ]] || die "Укажите профиль: switch <profile>"; switch_profile "$2" ;;
  save) [[ $# -eq 2 ]] || die "Укажите имя профиля: save <profile>"; save_current_to_named_profile "$2" ;;
  list) list_profiles ;;
  status) show_status ;;
  help|-h|--help) usage ;;
  *) usage; exit 2 ;;
esac
