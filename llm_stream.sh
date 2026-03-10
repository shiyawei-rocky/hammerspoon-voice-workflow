#!/bin/bash
# LLM 流式输出脚本
# 使用 curl 接收 SSE 流，解析 delta 内容写入临时文件
# 用法: llm_stream.sh <model> [endpoint] [prompt_file] [stream_file] [status_file] [rr_index_file]
# system_prompt 和 user_prompt 从临时文件读取

set -o pipefail

MODEL="$1"
ENDPOINT_ARG="$2"
PROMPT_FILE="${3:-${LLM_STREAM_PROMPT_FILE:-/tmp/llm_stream_prompt.json}}"
RAW_API_URL="${ENDPOINT_ARG:-${LLM_ENDPOINT:-https://api.siliconflow.cn/v1/chat/completions}}"
STREAM_FILE="${4:-${LLM_STREAM_FILE:-/tmp/llm_stream.txt}}"
STATUS_FILE="${5:-${LLM_STREAM_STATUS_FILE:-/tmp/llm_stream_status.txt}}"
RR_INDEX_FILE="${6:-${LLM_STREAM_RR_INDEX_FILE:-/tmp/llm_stream_key_rr_index}}"
KEYCHAIN_CANDIDATES="${LLM_KEYCHAIN_CANDIDATES:-siliconflow:siliconflow,siliconflow:siliconflow_2,siliconflow:siliconflow_3,siliconflow:siliconflow_4,zhongzhuan:default,zhongzhuan:default_2,zhongzhuan:default_3}"
RETRY_ON="${LLM_KEY_RETRY_ON:-401,429,5xx}"
MAX_SWITCHES="${LLM_KEY_MAX_SWITCHES:-2}"

KEY_POOL=()
LAST_HTTP_CODE=0

normalize_chat_endpoint() {
    local url="$1"
    url="${url#"${url%%[![:space:]]*}"}"
    url="${url%"${url##*[![:space:]]}"}"
    if [[ -z "$url" ]]; then
        return 1
    fi
    if [[ "$url" =~ /chat/completions/?$ ]]; then
        printf "%s" "$url"
        return 0
    fi
    if [[ "$url" =~ /v1/?$ ]]; then
        url="${url%/}"
        printf "%s/chat/completions" "$url"
        return 0
    fi
    printf "%s" "$url"
    return 0
}

if ! API_URL="$(normalize_chat_endpoint "$RAW_API_URL")"; then
    echo "error" > "$STATUS_FILE"
    echo "invalid_endpoint" > "$STREAM_FILE"
    exit 1
fi

# 退出时确保写入状态
trap 'if [[ "$(cat "$STATUS_FILE" 2>/dev/null)" != "done" ]]; then echo "error" > "$STATUS_FILE"; fi' EXIT

# 检查 jq
if ! command -v jq >/dev/null 2>&1; then
    echo "error" > "$STATUS_FILE"
    echo "missing_jq" > "$STREAM_FILE"
    exit 1
fi

# 检查 prompt 文件
if [ ! -f "$PROMPT_FILE" ]; then
    echo "error" > "$STATUS_FILE"
    echo "no_prompt_file" > "$STREAM_FILE"
    exit 1
fi

# 读取 prompt
SYSTEM_PROMPT=$(jq -r '.system' "$PROMPT_FILE" 2>/dev/null)
USER_PROMPT=$(jq -r '.user' "$PROMPT_FILE" 2>/dev/null)

if [ -z "$SYSTEM_PROMPT" ] || [ -z "$USER_PROMPT" ]; then
    echo "error" > "$STATUS_FILE"
    echo "invalid_prompt" > "$STREAM_FILE"
    exit 1
fi

add_key() {
    local key="$1"
    if [ -z "$key" ]; then
        return
    fi
    for existing in "${KEY_POOL[@]}"; do
        if [ "$existing" = "$key" ]; then
            return
        fi
    done
    KEY_POOL+=("$key")
}

load_keys_from_raw() {
    local raw="$1"
    local token
    while IFS= read -r token || [ -n "$token" ]; do
        [ -n "$token" ] && add_key "$token"
    done < <(printf "%s\n" "$raw" | tr ', \t\r\n' '\n')
}

load_key_pool() {
    if [ -n "${LLM_API_KEYS:-}" ]; then
        load_keys_from_raw "$LLM_API_KEYS"
    fi

    for var_name in SILICONFLOW_API_KEY ZHONGZHUAN_API_KEY OPENAI_API_KEY; do
        local raw="${!var_name:-}"
        if [ -n "$raw" ]; then
            load_keys_from_raw "$raw"
        fi
    done

    local old_ifs="$IFS"
    IFS=','
    for item in $KEYCHAIN_CANDIDATES; do
        local service="${item%%:*}"
        local account="${item#*:}"
        if [ "$account" = "$item" ]; then
            account="default"
        fi
        if [ -n "$service" ]; then
            local key
            key=$(security find-generic-password -s "$service" -a "$account" -w 2>/dev/null || true)
            [ -n "$key" ] && add_key "$key"
        fi
    done
    IFS="$old_ifs"
}

is_retryable_status() {
    local code="$1"
    case "$code" in
        ''|*[!0-9]*) return 1 ;;
    esac
    local old_ifs="$IFS"
    IFS=','
    for token in $RETRY_ON; do
        token=$(printf "%s" "$token" | tr -d '[:space:]')
        [ -z "$token" ] && continue
        if [ "$token" = "5xx" ] && [ "$code" -ge 500 ] && [ "$code" -lt 600 ]; then
            IFS="$old_ifs"
            return 0
        fi
        if [ "$token" = "$code" ]; then
            IFS="$old_ifs"
            return 0
        fi
    done
    IFS="$old_ifs"
    return 1
}

select_start_index() {
    local count="${#KEY_POOL[@]}"
    if [ "$count" -le 1 ]; then
        echo 0
        return
    fi
    local idx=0
    if [ -f "$RR_INDEX_FILE" ]; then
        idx=$(cat "$RR_INDEX_FILE" 2>/dev/null || echo 0)
    fi
    case "$idx" in
        ''|*[!0-9]*) idx=0 ;;
    esac
    local start=$((idx % count))
    local next=$(((start + 1) % count))
    echo "$next" > "$RR_INDEX_FILE" 2>/dev/null || true
    echo "$start"
}

run_stream_with_key() {
    local key="$1"
    local key_idx="$2"
    local header_file raw_file curl_exit http_code
    header_file=$(mktemp /tmp/llm_stream_hdr_XXXXXX)
    raw_file=$(mktemp /tmp/llm_stream_raw_XXXXXX)

    echo -n "" > "$STREAM_FILE"
    echo "streaming" > "$STATUS_FILE"

    curl -sS --max-time 120 --no-buffer -D "$header_file" -X POST "$API_URL" \
        -H "Authorization: Bearer $key" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" 2>/dev/null | tee "$raw_file" | while IFS= read -r line; do
        
        if [[ -z "$line" || "$line" == ":"* ]]; then
            continue
        fi
        
        if [[ "$line" == data:* ]]; then
            data="${line#data: }"
            if [[ "$data" == "[DONE]" ]]; then
                echo "done" > "$STATUS_FILE"
                break
            fi
            content=$(echo "$data" | jq -r '.choices[0].delta.content // .choices[0].message.content // empty' 2>/dev/null)
            if [[ -n "$content" ]]; then
                printf "%s" "$content" >> "$STREAM_FILE"
            fi
        fi
    done
    curl_exit=${PIPESTATUS[0]}

    http_code=$(awk '/^HTTP/{code=$2} END{print code}' "$header_file")
    case "$http_code" in
        ''|*[!0-9]*) http_code=0 ;;
    esac
    LAST_HTTP_CODE="$http_code"

    if [ "$curl_exit" -ne 0 ] || [ "$http_code" -ne 200 ]; then
        echo "error" > "$STATUS_FILE"
        if [ -s "$raw_file" ]; then
            sed -n '1,5p' "$raw_file" > "$STREAM_FILE"
        else
            echo "http_$http_code" > "$STREAM_FILE"
        fi
        rm -f "$header_file" "$raw_file"
        return 1
    fi

    if [[ "$(cat "$STATUS_FILE" 2>/dev/null)" != "done" ]]; then
        if [[ -s "$STREAM_FILE" ]]; then
            echo "done" > "$STATUS_FILE"
        else
            echo "error" > "$STATUS_FILE"
            rm -f "$header_file" "$raw_file"
            return 1
        fi
    fi

    rm -f "$header_file" "$raw_file"
    return 0
}

# 构建 JSON payload
PAYLOAD=$(jq -n \
    --arg model "$MODEL" \
    --arg system "$SYSTEM_PROMPT" \
    --arg user "$USER_PROMPT" \
    '{
        model: $model,
        messages: [
            { role: "system", content: $system },
            { role: "user", content: $user }
        ],
        temperature: 0.3,
        stream: true
    }')

load_key_pool
if [ "${#KEY_POOL[@]}" -eq 0 ]; then
    echo "error" > "$STATUS_FILE"
    echo "no_api_key" > "$STREAM_FILE"
    exit 1
fi

case "$MAX_SWITCHES" in
    ''|*[!0-9]*) MAX_SWITCHES=2 ;;
esac

start_idx=$(select_start_index)
current_idx="$start_idx"
switch_count=0
while :; do
    hs_key="${KEY_POOL[$current_idx]}"
    if run_stream_with_key "$hs_key" "$current_idx"; then
        break
    fi
    if [ "$switch_count" -ge "$MAX_SWITCHES" ]; then
        break
    fi
    if [ "${#KEY_POOL[@]}" -le 1 ]; then
        break
    fi
    if ! is_retryable_status "$LAST_HTTP_CODE"; then
        break
    fi
    next_idx=$(((current_idx + 1) % ${#KEY_POOL[@]}))
    echo "[whisper] stream key switch: ${current_idx} -> ${next_idx} (status=${LAST_HTTP_CODE})" >&2
    current_idx="$next_idx"
    switch_count=$((switch_count + 1))
done

# 确保状态更新
final_status="$(cat "$STATUS_FILE" 2>/dev/null || echo error)"
if [[ "$final_status" == "streaming" ]]; then
    if [[ -s "$STREAM_FILE" ]]; then
        echo "done" > "$STATUS_FILE"
    else
        echo "error" > "$STATUS_FILE"
        exit 1
    fi
elif [[ "$final_status" != "done" ]]; then
    echo "error" > "$STATUS_FILE"
    exit 1
fi
