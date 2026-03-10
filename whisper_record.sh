#!/bin/bash
# Whisper 录音脚本
# 用法: whisper_record.sh start|stop|status

TMP_BASE="${TMPDIR:-/tmp}"
if [[ "$TMP_BASE" != */ ]]; then
    TMP_BASE="${TMP_BASE}/"
fi
RECORD_PID_FILE="${WHISPER_RECORD_PID_FILE:-${TMP_BASE}whisper_record.pid}"
AUDIO_FILE="${WHISPER_AUDIO_FILE:-${TMP_BASE}whisper_input.wav}"
FFMPEG="/opt/homebrew/bin/ffmpeg"
MAX_DURATION=${WHISPER_MAX_DURATION:-1800}

start_recording() {
    # 如果已在录音，先停止
    if [ -f "$RECORD_PID_FILE" ]; then
        stop_recording
    fi
    
    # 获取默认麦克风设备
    MIC_DEVICE=":0"
    
    if [ ! -x "$FFMPEG" ]; then
        FFMPEG="$(command -v ffmpeg 2>/dev/null || true)"
    fi
    if [ -z "$FFMPEG" ] || [ ! -x "$FFMPEG" ]; then
        echo "missing_ffmpeg"
        return
    fi
    
    # 开始录音（后台运行）
    $FFMPEG -y -f avfoundation -i "$MIC_DEVICE" -t $MAX_DURATION \
        -ar 16000 -ac 1 -c:a pcm_s16le "$AUDIO_FILE" \
        >/dev/null 2>&1 &
    
    echo $! > "$RECORD_PID_FILE"
    echo "recording"
}

stop_recording() {
    if [ -f "$RECORD_PID_FILE" ]; then
        PID=$(cat "$RECORD_PID_FILE")
        if kill -0 "$PID" 2>/dev/null; then
            # 使用 SIGINT 让 ffmpeg 优雅退出，正确刷新缓冲区
            kill -INT "$PID" 2>/dev/null
            # 等待进程结束
            for i in {1..10}; do
                kill -0 "$PID" 2>/dev/null || break
                sleep 0.1
            done
        fi
        rm -f "$RECORD_PID_FILE"
    fi
    
    # 检查音频文件
    if [ -f "$AUDIO_FILE" ] && [ $(stat -f%z "$AUDIO_FILE" 2>/dev/null || echo 0) -gt 1024 ]; then
        echo "stopped"
    else
        echo "no_audio"
    fi
}

get_status() {
    if [ -f "$RECORD_PID_FILE" ] && kill -0 $(cat "$RECORD_PID_FILE") 2>/dev/null; then
        echo "recording"
    else
        echo "idle"
    fi
}

clean_temp_files() {
    local audio_dir
    audio_dir="$(dirname "$AUDIO_FILE")"
    if [ -z "$audio_dir" ] || [ "$audio_dir" = "." ]; then
        audio_dir="/tmp"
    fi
    rm -f "${audio_dir}"/whisper_*.wav "${audio_dir}"/whisper_*.json "$RECORD_PID_FILE" 2>/dev/null
    echo "cleaned"
}

case "$1" in
    start)
        start_recording
        ;;
    stop)
        stop_recording
        ;;
    status)
        get_status
        ;;
    clean)
        clean_temp_files
        ;;
    *)
        echo "Usage: $0 {start|stop|status|clean}"
        exit 1
        ;;
esac
