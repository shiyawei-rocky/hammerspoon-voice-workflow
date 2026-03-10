-- normalize_spoken_numbers: 中文口述数字转阿拉伯数字
local cfg_value = require("lib.utils").cfg_value

local M = {}

local function sanitize_utf8_or_keep(text)
    local value = tostring(text or "")
    local ok, len = pcall(utf8.len, value)
    if ok and type(len) == "number" then
        return value, true
    end
    local out = {}
    for ch in value:gmatch(utf8.charpattern) do
        table.insert(out, ch)
    end
    local cleaned = table.concat(out)
    local ok2, len2 = pcall(utf8.len, cleaned)
    return cleaned, ok2 and type(len2) == "number"
end

function M.normalize(text, enabled)
    if not text or text == "" then
        return text
    end
    if not enabled then
        return text
    end
    local valid_utf8 = false
    text, valid_utf8 = sanitize_utf8_or_keep(text)
    if not valid_utf8 then
        hs.printf("[whisper] normalize_spoken_numbers skipped: invalid UTF-8")
        return text
    end

    local digit_map = {
        ["零"] = 0, ["〇"] = 0,
        ["一"] = 1, ["壹"] = 1,
        ["二"] = 2, ["两"] = 2, ["贰"] = 2,
        ["三"] = 3, ["叁"] = 3,
        ["四"] = 4, ["肆"] = 4,
        ["五"] = 5, ["伍"] = 5,
        ["六"] = 6, ["陆"] = 6,
        ["七"] = 7, ["柒"] = 7,
        ["八"] = 8, ["捌"] = 8,
        ["九"] = 9, ["玖"] = 9,
    }
    local unit_map = {
        ["十"] = 10, ["拾"] = 10,
        ["百"] = 100, ["佰"] = 100,
        ["千"] = 1000, ["仟"] = 1000,
        ["万"] = 10000, ["萬"] = 10000,
        ["亿"] = 100000000, ["億"] = 100000000,
    }

    local function cn_to_int(s)
        local total = 0
        local section = 0
        local number = 0
        local ok = pcall(function()
            for _, code in utf8.codes(s) do
                local c = utf8.char(code)
                local d = digit_map[c]
                local u = unit_map[c]
                if d ~= nil then
                    number = d
                elseif u ~= nil then
                    if u == 10000 or u == 100000000 then
                        section = section + number
                        if section == 0 then
                            section = 1
                        end
                        total = total + section * u
                        section = 0
                        number = 0
                    else
                        if number == 0 then
                            number = 1
                        end
                        section = section + number * u
                        number = 0
                    end
                else
                    error("invalid_cn_char")
                end
            end
        end)
        if not ok then
            return nil
        end
        return total + section + number
    end

    local function cn_digits_only_to_int(s)
        local out = {}
        local ok = pcall(function()
            for _, code in utf8.codes(s) do
                local c = utf8.char(code)
                local d = digit_map[c]
                if d == nil then
                    error("invalid_cn_digit")
                end
                table.insert(out, tostring(d))
            end
        end)
        if not ok then
            return nil
        end
        return tonumber(table.concat(out))
    end

    local function convert_match(m)
        if m:find("[几多来余半上下约左右]") then
            return m
        end
        local has_unit = m:find("[十拾百佰千仟万萬亿億点]") ~= nil
        local len = (utf8.len(m) or #m)
        if not has_unit and len < 2 then
            return m
        end

        local int_part = m
        local dec_part = nil
        if m:find("点") then
            int_part, dec_part = m:match("^(.-)点(.+)$")
        end

        local int_num = nil
        if not int_part or int_part == "" then
            int_num = 0
        else
            if not has_unit then
                int_num = cn_digits_only_to_int(int_part)
            else
                int_num = cn_to_int(int_part)
            end
        end

        if int_num == nil then
            return m
        end

        if dec_part and dec_part ~= "" then
            local dec_digits = {}
            local ok = pcall(function()
                for _, code in utf8.codes(dec_part) do
                    local c = utf8.char(code)
                    local d = digit_map[c]
                    if d == nil then
                        error("invalid_cn_decimal")
                    end
                    table.insert(dec_digits, tostring(d))
                end
            end)
            if not ok then
                return m
            end
            return tostring(int_num) .. "." .. table.concat(dec_digits)
        end

        return tostring(int_num)
    end

    local pattern = "[零〇一二两三四五六七八九壹贰叁肆伍陆柒捌玖十拾百佰千仟万萬亿億点]+"
    return (text:gsub(pattern, convert_match))
end

M.sanitize_utf8_or_keep = sanitize_utf8_or_keep

return M
