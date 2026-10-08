#!/bin/zsh

set -eu

readonly SCRIPT_DIR="${0:A:h}"
readonly STATE_FILE="${SCRIPT_DIR}/.state"
readonly LOCK_FILE="${SCRIPT_DIR}/.lock"
readonly TOKEN_SERVICE="codex-power-monitor-telegram-token"
readonly CHAT_SERVICE="codex-power-monitor-telegram-chat-id"
readonly ACCOUNT_NAME="$(/usr/bin/id -un)"
readonly INACTIVE_SECONDS=30
readonly MODE="${1:-check}"

if [[ -x /opt/homebrew/bin/jq ]]; then
  readonly JQ_PATH=/opt/homebrew/bin/jq
else
  readonly JQ_PATH=/usr/bin/jq
fi

integer lock_since=0
integer last_alert_message_id=0
integer lock_attempts=0

while ! /usr/bin/shlock -p $$ -f "$LOCK_FILE"; do
  lock_attempts=$(( lock_attempts + 1 ))
  if (( lock_attempts >= 20 )); then
    exit 0
  fi
  /bin/sleep 0.1
done

release_lock() {
  /bin/rm -f "$LOCK_FILE"
}

trap release_lock EXIT HUP INT TERM

if [[ -f "$STATE_FILE" ]]; then
  source "$STATE_FILE"
fi

power_summary="$(/usr/bin/pmset -g batt)"
battery_percent="$(print -r -- "$power_summary" | /usr/bin/sed -nE 's/.*[[:space:]]([0-9]+)%;.*/\1/p' | /usr/bin/head -n 1)"

if [[ -z "$battery_percent" ]]; then
  print -u2 -- "Could not read the MacBook battery percentage."
  exit 1
fi

if [[ "$power_summary" == *"Now drawing from 'AC Power'"* ]]; then
  plugged_in=1
else
  plugged_in=0
fi

locked_raw="$(/usr/sbin/ioreg -n Root -d1 -a | /usr/bin/plutil -extract IOConsoleLocked raw -o - - 2>/dev/null)"
if [[ "$locked_raw" == "true" ]]; then
  locked=1
else
  locked=0
fi

idle_ns="$(/usr/sbin/ioreg -c IOHIDSystem | /usr/bin/awk -F'= ' '/HIDIdleTime/ { gsub(/ /, "", $2); print $2; exit }')"
integer idle_seconds=$(( ${idle_ns:-0} / 1000000000 ))
integer now_epoch="$(/bin/date +%s)"

send_telegram() {
  local message="$1"
  local token
  local chat_id
  local response

  token="$(/usr/bin/security find-generic-password -a "$ACCOUNT_NAME" -s "$TOKEN_SERVICE" -w 2>/dev/null)" || {
    print -u2 -- "Telegram bot token is not configured."
    return 1
  }
  chat_id="$(/usr/bin/security find-generic-password -a "$ACCOUNT_NAME" -s "$CHAT_SERVICE" -w 2>/dev/null)" || {
    print -u2 -- "Telegram chat ID is not configured."
    return 1
  }

  response="$(/usr/bin/curl \
    --silent \
    --show-error \
    --fail \
    --connect-timeout 2 \
    --max-time 4 \
    --request POST \
    "https://api.telegram.org/bot${token}/sendMessage" \
    --data-urlencode "chat_id=${chat_id}" \
    --data-urlencode "text=${message}")"

  last_alert_message_id="$(
    print -r -- "$response" |
      "$JQ_PATH" -r '.result.message_id // empty'
  )"

  if (( last_alert_message_id <= 0 )); then
    print -u2 -- "Telegram did not return a message ID."
    return 1
  fi
}

react_to_last_alert() {
  local token
  local chat_id

  token="$(/usr/bin/security find-generic-password -a "$ACCOUNT_NAME" -s "$TOKEN_SERVICE" -w 2>/dev/null)" || {
    print -u2 -- "Telegram bot token is not configured."
    return 1
  }
  chat_id="$(/usr/bin/security find-generic-password -a "$ACCOUNT_NAME" -s "$CHAT_SERVICE" -w 2>/dev/null)" || {
    print -u2 -- "Telegram chat ID is not configured."
    return 1
  }

  /usr/bin/curl \
    --silent \
    --show-error \
    --fail \
    --connect-timeout 3 \
    --max-time 10 \
    --output /dev/null \
    --request POST \
    "https://api.telegram.org/bot${token}/setMessageReaction" \
    --data-urlencode "chat_id=${chat_id}" \
    --data-urlencode "message_id=${last_alert_message_id}" \
    --data-urlencode 'reaction=[{"type":"emoji","emoji":"👍"}]'
}

choose_message() {
  local category="$1"
  local -a messages

  case "$category" in
    critical)
      messages=(
        "macbook má už len ${battery_percent} % a stále nie je na kábli"
        "batéria klesla na ${battery_percent} %. zišla by sa nabíjačka"
        "hej, macbook je na ${battery_percent} %"
        "len upozornenie, macbooku zostáva ${battery_percent} % batérie"
        "macbook je skoro vybitý a nie je pripojený k napájaniu"
        "zostáva ${battery_percent} %. radšej ho už pripoj"
        "macbook hlási ${battery_percent} % a stále ide z batérie"
        "batéria je na ${battery_percent} %. toto už je celkom na hrane"
        "macbooku pomaly dochádza energia, zostáva ${battery_percent} %"
        "kámo, ${battery_percent} % 😭 teraz by sa ten kábel fakt hodil"
      )
      ;;
    locked)
      messages=(
        "macbook je zamknutý a stále ide z batérie (${battery_percent} %)"
        "nechal si macbook zamknutý bez kábla"
        "len pripomínam, zamknutý macbook nie je pripojený k napájaniu"
        "macbook je už chvíľu zamknutý a má ${battery_percent} %"
        "vyzerá to, že si odišiel a macbook zostal odpojený"
        "macbook čaká zamknutý a beží z batérie"
        "hej, macbook je zamknutý, ale nabíjačka pripojená nie je"
        "pre istotu: macbook zostal bez kábla a má ${battery_percent} %"
        "macbook je stále zapnutý, zamknutý a odpojený"
        "ak si už odišiel, macbook zostal na batérii (${battery_percent} %)"
      )
      ;;
    pre-sleep)
      messages=(
        "macbook ide spať bez kábla, má ${battery_percent} %"
        "zavrel si macbook a nie je pripojený. batéria má ${battery_percent} %"
        "len pripomínam, macbook zaspáva odpojený od napájania"
        "macbook je zavretý a stále ide z batérie (${battery_percent} %)"
        "vyzerá to, že si zavrel macbook bez nabíjačky"
        "macbook práve zaspáva s ${battery_percent} % a bez kábla"
        "hej, macbook si zavrel odpojený"
        "macbook ide do režimu spánku, ale nabíjačka pripojená nie je"
        "pre istotu: zavretý macbook má ${battery_percent} % a beží z batérie"
        "macbook zaspal bez nabíjania. zostáva mu ${battery_percent} %"
      )
      ;;
    *)
      return 1
      ;;
  esac

  print -r -- "${messages[$(( RANDOM % ${#messages[@]} + 1 ))]}"
}

save_state() {
  {
    print -r -- "lock_since=${lock_since}"
    print -r -- "last_alert_message_id=${last_alert_message_id}"
  } > "$STATE_FILE"
}

if (( plugged_in )); then
  if (( last_alert_message_id > 0 )); then
    react_to_last_alert
    last_alert_message_id=0
  fi
  lock_since=0
  save_state
  exit 0
fi

if [[ "$MODE" == "--pre-sleep" ]]; then
  if (( last_alert_message_id == 0 )); then
    send_telegram "$(choose_message pre-sleep)"
  fi
  save_state
  exit 0
fi

if [[ "$MODE" == "--power-source-change" ]]; then
  if (( locked && last_alert_message_id == 0 )); then
    send_telegram "$(choose_message pre-sleep)"
  fi
  save_state
  exit 0
fi

if (( locked )); then
  if (( lock_since == 0 )); then
    lock_since=$now_epoch
  fi
else
  lock_since=0
fi

integer locked_seconds=0
if (( lock_since > 0 )); then
  locked_seconds=$(( now_epoch - lock_since ))
fi

if (( last_alert_message_id == 0 && battery_percent <= 10 && (locked || idle_seconds >= INACTIVE_SECONDS) )); then
  send_telegram "$(choose_message critical)"
elif (( last_alert_message_id == 0 && locked_seconds >= INACTIVE_SECONDS )); then
  send_telegram "$(choose_message locked)"
fi

save_state
