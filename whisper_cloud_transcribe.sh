#!/bin/bash
# 云端 ASR 转录脚本（OpenAI 兼容 chat/completions）
# 使用 Qwen3-Omni 多模态模型（chat/completions）
# 支持长音频自动分段转写
# 用法: whisper_cloud_transcribe.sh [audio_file] [endpoint] [api_key_env] [keychain_service] [keychain_account] [api_key_envs] [keychain_candidates] [max_switches] [key_retry_on] [request_retry_on] [request_max_retries] [request_backoff_ms] [request_backoff_max_ms] [audio_normalize] [audio_sample_rate] [audio_channels] [model] [provider_name]

AUDIO_FILE="${1:-/tmp/whisper_input.wav}"
API_URL="${2:-${ASR_ENDPOINT:-https://api.siliconflow.cn/v1/chat/completions}}"
ASR_API_KEY_ENV="${3:-SILICONFLOW_API_KEY}"
ASR_KEYCHAIN_SERVICE="${4:-siliconflow}"
ASR_KEYCHAIN_ACCOUNT="${5:-siliconflow}"
ASR_API_KEY_ENVS="${6:-}"
ASR_KEYCHAIN_CANDIDATES="${7:-}"
ASR_KEY_MAX_SWITCHES="${8:-1}"
ASR_KEY_RETRY_ON="${9:-401,403,429,5xx}"
ASR_REQUEST_RETRY_ON="${10:-429,5xx,timeout}"
ASR_REQUEST_MAX_RETRIES="${11:-1}"
ASR_REQUEST_BACKOFF_MS="${12:-300}"
ASR_REQUEST_BACKOFF_MAX_MS="${13:-800}"
ASR_AUDIO_NORMALIZE="${14:-1}"
ASR_AUDIO_SAMPLE_RATE="${15:-16000}"
ASR_AUDIO_CHANNELS="${16:-1}"
MODEL="${17:-Qwen/Qwen3-Omni-30B-A3B-Instruct}"
ASR_PROVIDER_NAME="${18:-siliconflow}"
TIMEOUT=180
CHUNK_SEC=30
BYTES_PER_SEC=32000
FFMPEG="/opt/homebrew/bin/ffmpeg"
KEY_POOL=()
ASR_LAST_HTTP_CODE=0
RR_INDEX_FILE="/tmp/asr_key_rr_index"
ASR_RETRY_COUNT=0
ASR_PROVIDER_STATUS="init"
ASR_REQUEST_MS=0
ASR_METRICS_EMITTED=0
WORK_AUDIO_FILE="$AUDIO_FILE"

now_ms() {
    python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
}

ms_to_sec() {
    awk "BEGIN { printf \"%.3f\", $1 / 1000 }"
}

calc_backoff_ms() {
    local attempt="$1"
    local base="$ASR_REQUEST_BACKOFF_MS"
    local max="$ASR_REQUEST_BACKOFF_MAX_MS"
    case "$attempt" in
        ''|*[!0-9]*) attempt=0 ;;
    esac
    case "$base" in
        ''|*[!0-9]*) base=300 ;;
    esac
    case "$max" in
        ''|*[!0-9]*) max=800 ;;
    esac
    local delay="$base"
    local i=0
    while [ "$i" -lt "$attempt" ]; do
        delay=$((delay * 2))
        i=$((i + 1))
    done
    if [ "$delay" -gt "$max" ]; then
        delay="$max"
    fi
    echo "$delay"
}

emit_asr_metrics() {
    if [ "$ASR_METRICS_EMITTED" -eq 1 ]; then
        return
    fi
    if [ "${ASR_REQUEST_MS:-0}" -le 0 ]; then
        ASR_REQUEST_MS=$(( $(now_ms) - SCRIPT_START_MS ))
    fi
    ASR_METRICS_EMITTED=1
    echo "[whisper] asr_metrics provider=${ASR_PROVIDER_NAME} model=${MODEL} request_ms=${ASR_REQUEST_MS:-0} retry_count=${ASR_RETRY_COUNT:-0} provider_status=${ASR_PROVIDER_STATUS:-unknown}" >&2
}

SCRIPT_START_MS="$(now_ms)"
trap emit_asr_metrics EXIT

if [ ! -x "$FFMPEG" ]; then
    FFMPEG="$(command -v ffmpeg 2>/dev/null || true)"
fi

add_key() {
    local key="$1"
    [ -z "$key" ] && return
    for existing in "${KEY_POOL[@]}"; do
        [ "$existing" = "$key" ] && return
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
    # Primary env
    if [ -n "$ASR_API_KEY_ENV" ]; then
        load_keys_from_raw "${!ASR_API_KEY_ENV:-}"
    fi
    # Extra env list
    if [ -n "$ASR_API_KEY_ENVS" ]; then
        local old_ifs="$IFS"
        IFS=','
        for env_name in $ASR_API_KEY_ENVS; do
            env_name="$(printf "%s" "$env_name" | tr -d '[:space:]')"
            [ -n "$env_name" ] && load_keys_from_raw "${!env_name:-}"
        done
        IFS="$old_ifs"
    fi
    # Backward compatibility env（按 provider 定向，避免跨供应商 key 误用）
    if [[ "$ASR_PROVIDER_NAME" == *aliyun* ]] || [[ "$API_URL" == *dashscope.aliyuncs.com* ]]; then
        load_keys_from_raw "${DASHSCOPE_API_KEY:-}"
    else
        load_keys_from_raw "${SILICONFLOW_API_KEY:-}"
    fi

    # Primary keychain pair
    if [ -n "$ASR_KEYCHAIN_SERVICE" ]; then
        local key
        key=$(security find-generic-password -s "$ASR_KEYCHAIN_SERVICE" -a "$ASR_KEYCHAIN_ACCOUNT" -w 2>/dev/null || true)
        [ -n "$key" ] && add_key "$key"
    fi

    # Extra keychain candidates
    if [ -n "$ASR_KEYCHAIN_CANDIDATES" ]; then
        local old_ifs="$IFS"
        IFS=','
        for item in $ASR_KEYCHAIN_CANDIDATES; do
            local service account key
            service="${item%%:*}"
            account="${item#*:}"
            if [ "$account" = "$item" ]; then
                account=""
            fi
            if [ -n "$service" ]; then
                key=$(security find-generic-password -s "$service" -a "$account" -w 2>/dev/null || true)
                [ -n "$key" ] && add_key "$key"
            fi
        done
        IFS="$old_ifs"
    fi

    # Final fallback defaults（按 provider 定向）
    local key
    if [[ "$ASR_PROVIDER_NAME" == *aliyun* ]] || [[ "$API_URL" == *dashscope.aliyuncs.com* ]]; then
        key=$(security find-generic-password -s aliyun_dashscope -a default -w 2>/dev/null || true)
        [ -n "$key" ] && add_key "$key"
        key=$(security find-generic-password -s aliyun_dashscope -a default_2 -w 2>/dev/null || true)
        [ -n "$key" ] && add_key "$key"
        key=$(security find-generic-password -s aliyun_dashscope -a default_3 -w 2>/dev/null || true)
        [ -n "$key" ] && add_key "$key"
        key=$(security find-generic-password -s aliyun_dashscope -a default_4 -w 2>/dev/null || true)
        [ -n "$key" ] && add_key "$key"
    else
        key=$(security find-generic-password -s siliconflow -a siliconflow -w 2>/dev/null || true)
        [ -n "$key" ] && add_key "$key"
        key=$(security find-generic-password -s siliconflow -a siliconflow_2 -w 2>/dev/null || true)
        [ -n "$key" ] && add_key "$key"
    fi
}

is_retryable_status() {
    local code="$1"
    case "$code" in
        ''|*[!0-9]*) return 1 ;;
    esac
    local old_ifs="$IFS"
    IFS=','
    for token in $ASR_KEY_RETRY_ON; do
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

request_retryable_status() {
    local code="$1"
    local old_ifs="$IFS"
    IFS=','
    for token in $ASR_REQUEST_RETRY_ON; do
        token=$(printf "%s" "$token" | tr -d '[:space:]')
        [ -z "$token" ] && continue
        if [ "$token" = "5xx" ]; then
            if [ "$code" -ge 500 ] && [ "$code" -lt 600 ]; then
                IFS="$old_ifs"
                return 0
            fi
            continue
        fi
        if [ "$token" = "$code" ]; then
            IFS="$old_ifs"
            return 0
        fi
    done
    IFS="$old_ifs"
    return 1
}

request_retryable_timeout() {
    local old_ifs="$IFS"
    IFS=','
    for token in $ASR_REQUEST_RETRY_ON; do
        token=$(printf "%s" "$token" | tr -d '[:space:]')
        if [ "$token" = "timeout" ]; then
            IFS="$old_ifs"
            return 0
        fi
    done
    IFS="$old_ifs"
    return 1
}

prepare_audio_file() {
    if [ "$ASR_AUDIO_NORMALIZE" = "0" ]; then
        WORK_AUDIO_FILE="$AUDIO_FILE"
        return 0
    fi
    local normalized tmp_base
    tmp_base="$(mktemp /tmp/whisper_norm_XXXXXX)"
    normalized="${tmp_base}.wav"
    rm -f "$tmp_base"
    "$FFMPEG" -y -i "$AUDIO_FILE" -ar "$ASR_AUDIO_SAMPLE_RATE" -ac "$ASR_AUDIO_CHANNELS" -c:a pcm_s16le "$normalized" >/dev/null 2>&1
    if [ $? -ne 0 ] || [ ! -s "$normalized" ]; then
        rm -f "$normalized"
        WORK_AUDIO_FILE="$AUDIO_FILE"
        return 1
    fi
    WORK_AUDIO_FILE="$normalized"
    return 0
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

if [ -z "$MODEL" ]; then
    ASR_PROVIDER_STATUS="missing_model"
    echo '{"error": "missing_model"}'
    exit 1
fi

load_key_pool
if [ "${#KEY_POOL[@]}" -eq 0 ]; then
    ASR_PROVIDER_STATUS="no_api_key"
    echo '{"error": "no_api_key"}'
    exit 1
fi

case "$ASR_KEY_MAX_SWITCHES" in
    ''|*[!0-9]*) ASR_KEY_MAX_SWITCHES=1 ;;
esac
case "$ASR_REQUEST_MAX_RETRIES" in
    ''|*[!0-9]*) ASR_REQUEST_MAX_RETRIES=1 ;;
esac
case "$ASR_REQUEST_BACKOFF_MS" in
    ''|*[!0-9]*) ASR_REQUEST_BACKOFF_MS=300 ;;
esac
case "$ASR_REQUEST_BACKOFF_MAX_MS" in
    ''|*[!0-9]*) ASR_REQUEST_BACKOFF_MAX_MS=800 ;;
esac

if ! command -v jq >/dev/null 2>&1; then
    ASR_PROVIDER_STATUS="missing_jq"
    echo '{"error": "missing_jq"}'
    exit 1
fi

# 检查音频文件
if [ ! -f "$AUDIO_FILE" ] || [ ! -s "$AUDIO_FILE" ]; then
    ASR_PROVIDER_STATUS="no_audio_file"
    echo '{"error": "no_audio_file"}'
    exit 1
fi

if [ -z "$FFMPEG" ] || [ ! -x "$FFMPEG" ]; then
    ASR_PROVIDER_STATUS="missing_ffmpeg"
    echo '{"error": "missing_ffmpeg"}'
    exit 1
fi

transcribe_file_with_key() {
    local file="$1"
    local api_key="$2"
    local b64_file payload_file result text curl_exit attempt http_code body

    b64_file=$(mktemp /tmp/whisper_b64_XXXXXX)
    payload_file=$(mktemp /tmp/whisper_payload_XXXXXX)
    base64 < "$file" | tr -d '\n' > "$b64_file"
    if [ ! -s "$b64_file" ]; then
        rm -f "$b64_file" "$payload_file"
        return 2
    fi

    if [[ "$ASR_PROVIDER_NAME" == *aliyun* ]] || [[ "$API_URL" == *dashscope.aliyuncs.com* ]]; then
        jq -n \
            --arg model "$MODEL" \
            --rawfile audio "$b64_file" \
            '{
                model: $model,
                messages: [
                    { role: "user", content: [
                        { type: "input_audio", input_audio: { data: ("data:audio/wav;base64," + $audio) } }
                    ] }
                ],
                stream: false,
                asr_options: {
                    enable_itn: false
                }
            }' > "$payload_file"
    else
        jq -n \
            --arg model "$MODEL" \
            --rawfile audio "$b64_file" \
            --arg text "请转录这段音频" \
            '{
                model: $model,
                messages: [
                    { role: "system", content: "你是语音转写助手。只输出转写文本，不要解释。" },
                    { role: "user", content: [
                        { type: "audio_url", audio_url: { url: ("data:audio/wav;base64," + $audio) } },
                        { type: "text", text: $text }
                    ] }
                ],
                modalities: ["text"]
            }' > "$payload_file"
    fi
    if [ ! -s "$payload_file" ]; then
        rm -f "$b64_file" "$payload_file"
        return 2
    fi

    attempt=0
    while :; do
        result=$(curl -s --connect-timeout 10 --max-time "$TIMEOUT" \
            -w '\n__HTTP__:%{http_code}' \
            -H "Authorization: Bearer $api_key" \
            -H "Content-Type: application/json" \
            --data-binary @"$payload_file" \
            "$API_URL" 2>/dev/null)
        curl_exit=$?
        if [ $curl_exit -ne 0 ] || [ -z "$result" ]; then
            ASR_LAST_HTTP_CODE=0
            ASR_PROVIDER_STATUS="timeout"
            if [ "$attempt" -lt "$ASR_REQUEST_MAX_RETRIES" ] && request_retryable_timeout; then
                local delay_ms
                delay_ms=$(calc_backoff_ms "$attempt")
                ASR_RETRY_COUNT=$((ASR_RETRY_COUNT + 1))
                sleep "$(ms_to_sec "$delay_ms")"
                attempt=$((attempt + 1))
                continue
            fi
            rm -f "$b64_file" "$payload_file"
            return 3
        fi

        http_code=$(printf "%s" "$result" | sed -n 's/^__HTTP__://p' | tail -n1)
        body=$(printf "%s" "$result" | sed '/^__HTTP__:/d')
        case "$http_code" in
            ''|*[!0-9]*) http_code=0 ;;
        esac
        ASR_LAST_HTTP_CODE="$http_code"
        ASR_PROVIDER_STATUS="$http_code"

        if [ "$http_code" -eq 200 ] && ! echo "$body" | grep -q '"error"'; then
            text=$(echo "$body" | jq -r '
        .choices[0].message.content // empty
        | if type=="string" then .
          elif type=="array" then ([.[] | if type=="string" then . elif .text then .text else empty end] | join(""))
          else empty end
    ' 2>/dev/null)
            if [ -z "$text" ]; then
                rm -f "$b64_file" "$payload_file"
                ASR_PROVIDER_STATUS="empty_text"
                return 5
            fi
            rm -f "$b64_file" "$payload_file"
            printf "%s" "$text"
            return 0
        fi

        if [ -n "$body" ]; then
            echo "$body" >&2
        fi
        if [ "$attempt" -lt "$ASR_REQUEST_MAX_RETRIES" ] && request_retryable_status "$http_code"; then
            local delay_ms
            delay_ms=$(calc_backoff_ms "$attempt")
            ASR_RETRY_COUNT=$((ASR_RETRY_COUNT + 1))
            sleep "$(ms_to_sec "$delay_ms")"
            attempt=$((attempt + 1))
            continue
        fi
        rm -f "$b64_file" "$payload_file"
        return 4
    done

    rm -f "$b64_file" "$payload_file"
    ASR_PROVIDER_STATUS="request_failed"
    return 3
}

transcribe_file() {
    local file="$1"
    local count="${#KEY_POOL[@]}"
    local start_idx current_idx switch_count max_switches key

    start_idx=$(select_start_index)
    current_idx="$start_idx"
    switch_count=0
    max_switches="$ASR_KEY_MAX_SWITCHES"
    if [ "$count" -le 1 ]; then
        max_switches=0
    elif [ "$max_switches" -gt $((count - 1)) ]; then
        max_switches=$((count - 1))
    fi

    while :; do
        key="${KEY_POOL[$current_idx]}"
        if transcribe_file_with_key "$file" "$key"; then
            return 0
        fi
        if [ "$switch_count" -ge "$max_switches" ]; then
            break
        fi
        if ! is_retryable_status "$ASR_LAST_HTTP_CODE"; then
            break
        fi
        local next_idx=$(((current_idx + 1) % count))
        echo "[whisper] asr key switch: ${current_idx} -> ${next_idx} (status=${ASR_LAST_HTTP_CODE})" >&2
        current_idx="$next_idx"
        switch_count=$((switch_count + 1))
        ASR_RETRY_COUNT=$((ASR_RETRY_COUNT + 1))
    done
    return 1
}

prepare_audio_file >/dev/null 2>&1 || true
file_size=$(stat -f%z "$WORK_AUDIO_FILE" 2>/dev/null || echo 0)
dur_est=$((file_size / BYTES_PER_SEC))

if [ "$dur_est" -le "$CHUNK_SEC" ]; then
    out_file="/tmp/whisper_asr_out_$$.txt"
    if ! transcribe_file "$WORK_AUDIO_FILE" > "$out_file"; then
        rm -f "$out_file"
        ASR_PROVIDER_STATUS="${ASR_PROVIDER_STATUS:-asr_request_failed}"
        echo '{"error": "asr_request_failed"}'
        exit 1
    fi
    text="$(cat "$out_file" 2>/dev/null || true)"
    rm -f "$out_file"
else
    tmp_dir="/tmp/whisper_chunks_$$"
    mkdir -p "$tmp_dir"
    "$FFMPEG" -y -i "$WORK_AUDIO_FILE" -f segment -segment_time "$CHUNK_SEC" -reset_timestamps 1 \
        "$tmp_dir/chunk_%03d.wav" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        rm -rf "$tmp_dir"
        ASR_PROVIDER_STATUS="split_failed"
        echo '{"error": "split_failed"}'
        exit 1
    fi

    text=""
    for chunk in "$tmp_dir"/chunk_*.wav; do
        [ -e "$chunk" ] || continue
        part_file="/tmp/whisper_asr_chunk_$$.txt"
        if ! transcribe_file "$chunk" > "$part_file"; then
            rm -f "$part_file"
            rm -rf "$tmp_dir"
            ASR_PROVIDER_STATUS="chunk_transcribe_failed"
            echo '{"error": "chunk_transcribe_failed"}'
            exit 1
        fi
        part="$(cat "$part_file" 2>/dev/null || true)"
        rm -f "$part_file"
        if [ -n "$text" ]; then
            text="${text}"$'\n'
        fi
        text="${text}${part}"
    done
    rm -rf "$tmp_dir"
fi

if [ "$WORK_AUDIO_FILE" != "$AUDIO_FILE" ]; then
    rm -f "$WORK_AUDIO_FILE"
fi

if [ -z "$text" ]; then
    ASR_PROVIDER_STATUS="empty_transcription"
    echo '{"error": "empty_transcription"}'
    exit 1
fi

text_json=$(printf "%s" "$text" | jq -Rs .)
ASR_PROVIDER_STATUS="${ASR_PROVIDER_STATUS:-200}"
ASR_REQUEST_MS=$(( $(now_ms) - SCRIPT_START_MS ))
echo "{\"text\": $text_json}"
