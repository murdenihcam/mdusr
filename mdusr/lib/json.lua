-- minimal JSON decode/encode for mdusr
-- decode: objects -> tables, arrays -> tables with n-length, null -> nil
local json = {}

local function err(s, i, msg)
  error(("json: %s at char %d"):format(msg, i), 0)
end

local function skip(s, i)
  local _, e = s:find("^[ \t\r\n]*", i)
  return e + 1
end

local escapes = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }

local function utf8char(cp)
  if cp < 0x80 then return string.char(cp)
  elseif cp < 0x800 then return string.char(0xC0 | (cp >> 6), 0x80 | (cp & 0x3F))
  elseif cp < 0x10000 then return string.char(0xE0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F))
  else return string.char(0xF0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3F), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F)) end
end

local parse

local function parse_string(s, i)
  -- s:sub(i,i) == '"'
  local out, j = {}, i + 1
  while true do
    local c = s:sub(j, j)
    if c == "" then err(s, j, "unterminated string") end
    if c == '"' then return table.concat(out), j + 1 end
    if c == "\\" then
      local e = s:sub(j + 1, j + 1)
      if e == "u" then
        local hex = s:sub(j + 2, j + 5)
        local cp = tonumber(hex, 16) or err(s, j, "bad \\u escape")
        j = j + 6
        if cp >= 0xD800 and cp <= 0xDBFF and s:sub(j, j + 1) == "\\u" then
          local lo = tonumber(s:sub(j + 2, j + 5), 16)
          if lo and lo >= 0xDC00 and lo <= 0xDFFF then
            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
            j = j + 6
          end
        end
        out[#out + 1] = utf8char(cp)
      else
        out[#out + 1] = escapes[e] or err(s, j, "bad escape")
        j = j + 2
      end
    else
      local k = s:find('["\\]', j)
      if not k then err(s, j, "unterminated string") end
      out[#out + 1] = s:sub(j, k - 1)
      j = k
    end
  end
end

parse = function(s, i)
  i = skip(s, i)
  local c = s:sub(i, i)
  if c == "{" then
    local t = {}
    i = skip(s, i + 1)
    if s:sub(i, i) == "}" then return t, i + 1 end
    while true do
      if s:sub(i, i) ~= '"' then err(s, i, "expected key") end
      local k
      k, i = parse_string(s, i)
      i = skip(s, i)
      if s:sub(i, i) ~= ":" then err(s, i, "expected ':'") end
      local v
      v, i = parse(s, i + 1)
      t[k] = v
      i = skip(s, i)
      c = s:sub(i, i)
      if c == "}" then return t, i + 1 end
      if c ~= "," then err(s, i, "expected ',' or '}'") end
      i = skip(s, i + 1)
    end
  elseif c == "[" then
    local t, n = {}, 0
    i = skip(s, i + 1)
    if s:sub(i, i) == "]" then return t, i + 1 end
    while true do
      local v
      v, i = parse(s, i)
      n = n + 1
      t[n] = v
      i = skip(s, i)
      c = s:sub(i, i)
      if c == "]" then return t, i + 1 end
      if c ~= "," then err(s, i, "expected ',' or ']'") end
      i = i + 1
    end
  elseif c == '"' then
    return parse_string(s, i)
  elseif s:find("^true", i) then return true, i + 4
  elseif s:find("^false", i) then return false, i + 5
  elseif s:find("^null", i) then return nil, i + 4
  else
    local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
    if num and #num > 0 then return tonumber(num), i + #num end
    err(s, i, "unexpected '" .. c .. "'")
  end
end

function json.decode(s)
  local ok, v, i = pcall(parse, s, 1)
  if not ok then return nil, v end
  return v
end

local function is_array(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" then return false end
    n = n + 1
  end
  return n == #t
end

local function enc_str(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    local m = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
    return m[c] or ("\\u%04x"):format(c:byte())
  end) .. '"'
end

function json.encode(v)
  local t = type(v)
  if t == "nil" then return "null"
  elseif t == "boolean" then return tostring(v)
  elseif t == "number" then
    if v == math.floor(v) and math.abs(v) < 2^53 then return ("%d"):format(v) end
    return ("%.14g"):format(v)
  elseif t == "string" then return enc_str(v)
  elseif t == "table" then
    local parts = {}
    if next(v) == nil then return "[]" end
    if is_array(v) then
      for i = 1, #v do parts[i] = json.encode(v[i]) end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    for _, k in ipairs(keys) do
      local val = v[k]
      if val == nil then val = v[tonumber(k)] end
      parts[#parts + 1] = enc_str(k) .. ":" .. json.encode(val)
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "null"
end

return json
