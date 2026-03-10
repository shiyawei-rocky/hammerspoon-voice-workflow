local function tmp_path(name)
  local base = os.getenv("TMPDIR") or "/tmp"
  if not base:match("/$") then
    base = base .. "/"
  end
  return base .. name
end

return {
  paths = {
    script_dir = os.getenv("HOME") .. "/.hammerspoon",
    audio_file = tmp_path("whisper_input.wav"),
    record_pid_file = tmp_path("whisper_record.pid"),
    stream_file = tmp_path("llm_stream.txt"),
    stream_status = tmp_path("llm_stream_status.txt"),
    prompt_file = tmp_path("llm_stream_prompt.json"),
    log_file = os.getenv("HOME") .. "/.hammerspoon/whisper.log",
  },
  llm = {
    enabled = true,
    endpoint = "https://api.example.com/v1/chat/completions",
    api_key_env = "YOUR_LLM_API_KEY",
    keychain_service = "your_service",
    keychain_account = "default",
    models = {
      quick = "your-quick-model",
      fast = "your-fast-model",
      strong = "your-strong-model",
    },
  },
  asr = {
    provider_name = "your_asr_provider",
    endpoint = "https://api.example.com/v1/chat/completions",
    api_key_env = "YOUR_ASR_API_KEY",
    keychain_service = "your_asr_service",
    keychain_account = "default",
    model = "your-asr-model",
  },
}
