#!/bin/zsh

set -eu

readonly TOKEN_SERVICE="codex-power-monitor-telegram-token"
readonly CHAT_SERVICE="codex-power-monitor-telegram-chat-id"
readonly ACCOUNT_NAME="$(/usr/bin/id -un)"

if [[ -x /opt/homebrew/bin/jq ]]; then
  readonly JQ_PATH=/opt/homebrew/bin/jq
else
  readonly JQ_PATH=/usr/bin/jq
fi

print -- "1. In Telegram, open @BotFather."
print -- "2. Send /newbot and follow its instructions."
print -- "3. Open the new bot's chat and press Start."
print -- "4. Paste the token from BotFather below."
print
read -rs "bot_token?Bot token: "
print

if [[ -z "$bot_token" ]]; then
  print -u2 -- "No token entered."
  exit 1
fi

updates="$(/usr/bin/curl --silent --show-error --fail "https://api.telegram.org/bot${bot_token}/getUpdates")" || {
  print -u2 -- "Telegram rejected the token."
  exit 1
}

chat_id="$(print -r -- "$updates" | "$JQ_PATH" -r '[.result[] | (.message.chat.id // .channel_post.chat.id // empty)] | last // empty')"

if [[ -z "$chat_id" ]]; then
  print -u2 -- "No chat found. Send your bot a message, then run this setup again."
  exit 1
fi

/usr/bin/security add-generic-password -U -a "$ACCOUNT_NAME" -s "$TOKEN_SERVICE" -w "$bot_token" >/dev/null
/usr/bin/security add-generic-password -U -a "$ACCOUNT_NAME" -s "$CHAT_SERVICE" -w "$chat_id" >/dev/null

print -- "Telegram credentials saved in macOS Keychain."
print -- "Sending a test message…"

/usr/bin/curl \
  --silent \
  --show-error \
  --fail \
  --output /dev/null \
  --request POST \
  "https://api.telegram.org/bot${bot_token}/sendMessage" \
  --data-urlencode "chat_id=${chat_id}" \
  --data-urlencode "text=MacBook power monitor connected. I’ll message you when the laptop needs to be plugged in."

print -- "Test message sent."
