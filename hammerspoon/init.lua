-- ⌘⇧V in FSNotes: paste clipboard URL as a Markdown link [Title](url)
--
-- Title resolution mirrors Noteplan (its binary references
-- WebURLsWithTitlesPboardType — it reads the title from the pasteboard):
--   1. INSTANT  pasteboard already has a title (public.url-name, html anchor,
--               WebURLsWithTitlesPboardType) → no network.
--   2. CACHE    URL pasted before (10 min) → no network.
--   3. FETCH    plain-text URL only → background curl → temp file (HS 1.1.1
--               bug: hs.task callbacks die on large child stdout), 3s cap,
--               hostname fallback. Visible 🔗 indicator while fetching.
--
-- DELIVERY (the important part): AXSelectedText insertion — the text is
-- written straight into the focused editor via the Accessibility API.
-- No synthetic keystrokes, no clipboard swap, no modifier coupling (held
-- ⌘⇧), no keyboard layout issues, no propagation races. Clipboard and
-- ⌘V-synthesis are only used as a rare fallback when AX is not settable.
--
-- Flight recorder: /tmp/hs-mdlink.log (ms timestamps, every press + path).
-- Test hook (terminal): hs -c 'MDLink.test("https://…")'

local FSNOTES_BUNDLE_ID = "co.fluder.FSNotes"
local LOG    = "/tmp/hs-mdlink.log"
local UA     = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

require("hs.ipc")  -- ground-truth checks from terminal:  hs -c '...'

local function logf(msg)
  local f = io.open(LOG, "a")
  if f then
    local s = hs.timer.secondsSinceEpoch()
    f:write(os.date("%H:%M:%S", math.floor(s)) .. string.format(".%03d", math.floor((s % 1) * 1000)) .. " " .. msg .. "\n"); f:close()
  end
end

local function nowMs() return math.floor(hs.timer.secondsSinceEpoch() * 1000) end

-- run fn(args) safely; Lua errors land in the flight recorder, not the void
local function guard(what, fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then logf("CALLBACK ERROR (" .. what .. "): " .. tostring(err)) end
end

-- Live physical-modifier state (updated by the recorder tap). Only needed by
-- the rare clipboard-fallback path: a synthetic ⌘V posted while the user
-- still holds ⌘⇧ arrives as ⌘⇧V in the app (FSNotes: Duplicate — no paste).
MODS = { cmd = false, shift = false }

-- Passive global recorder: sees ⌘⇧V / ⌘⇧D presses in ANY app.
-- MUST return nothing (nil) — returning true would CONSUME every keypress
-- system-wide (learned the hard way: true = swallow, nil = pass through).
keyRecorder = hs.eventtap.new({hs.eventtap.event.types.keyDown, hs.eventtap.event.types.flagsChanged}, function(ev)
  local flags = ev:getFlags()
  MODS.cmd = flags.cmd or false
  MODS.shift = flags.shift or false
  if ev:getType() == hs.eventtap.event.types.keyDown then
    local key = ev:getKeyCode()
    if (key == hs.keycodes.map["v"] or key == hs.keycodes.map["d"]) and flags.cmd and flags.shift then
      local front = hs.application.frontmostApplication()
      logf("PRESS " .. (key == hs.keycodes.map["v"] and "⌘⇧V" or "⌘⇧D") ..
           " seen by recorder | frontmost=" .. (front and front:bundleID() or "?"))
    end
  end
  return nil  -- passive observer: never intercept anything
end)
keyRecorder:start()

-- macOS can silently disable event taps (callback timeout); re-arm (same
-- lesson as the dictation app's tap watchdog).
tapWatchdog = hs.timer.doEvery(0.5, function()
  if not keyRecorder:isEnabled() then
    keyRecorder:start()
    logf("recorder tap re-armed (macOS had disabled it)")
  end
end)

-- wait until the user's physical ⌘/⇧ are released (or 1.5s timeout)
local function waitModsThen(fn, tag)
  local t0 = nowMs()
  local function check()
    if not (MODS.cmd or MODS.shift) or (nowMs() - t0) > 1500 then
      hs.timer.doAfter(0.03, function()
        guard(tag, function()
          if nowMs() - t0 > 40 then
            logf("mods wait " .. (nowMs() - t0) .. "ms" ..
                 ((MODS.cmd or MODS.shift) and " (TIMED OUT — still held)" or ""))
          end
          fn()
        end)
      end)
    else
      hs.timer.doAfter(0.02, check)
    end
  end
  check()
end

-- ------------------------- markdown link helpers -------------------------

local ENTITIES = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " " }

local function decodeEntities(s)
  s = s:gsub("&#(%d+);",  function(n) return utf8.char(tonumber(n) or 63) end)
  s = s:gsub("&#x(%x+);", function(n) return utf8.char(tonumber(n, 16) or 63) end)
  for k, v in pairs(ENTITIES) do s = s:gsub("&" .. k .. ";", v) end
  return s
end

local function cleanTitle(t)
  t = t:gsub("\194\160", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  -- NB: Lua patterns have no | alternation — strip each brand separately
  for _, brand in ipairs({ "YouTube", "GitHub", "Google", "Wikipedia" }) do
    t = t:gsub("%s*[-|]%s*" .. brand .. "$", "")
    t = t:gsub("%s*–%s*" .. brand .. "$", "")
  end
  return t
end

local function mdLink(title, url)
  local esc = title:gsub("%[", "\\["):gsub("%]", "\\]")
  local link = url
  if url:find("[()]") or url:find(" ") then link = "<" .. url .. ">" end
  return "[" .. esc .. "](" .. link .. ")"
end

local function hostname(url)
  return (url:match("^https?://([^/%s]+)") or url):gsub("^www%.", "")
end

-- Title already sitting on the pasteboard? (Noteplan's instant path)
local function instantTitle(d, url)
  local function ok(raw)
    if type(raw) ~= "string" then return nil end
    local t = cleanTitle(decodeEntities(raw))
    if t ~= "" and t ~= url and not t:match("^https?://") then return t end
  end
  local t = ok(d["public.url-name"]);              if t then return t, "url-name" end
  local html = d["public.html"] or d["text/html"]  -- Chromium "Copy Link Address" writes an anchor
  if html then
    local label = html:match("<[Aa]%s+[^>]->(.-)</[Aa]>") or html:match("<[Aa][^>]->(.-)</[Aa]>")
    t = ok(label);                                  if t then return t, "html-anchor" end
  end
  local wt = d["WebURLsWithTitlesPboardType"]       -- Safari: two arrays (urls, then titles)
  if wt then
    local strs = {}
    for s in wt:gmatch("<string>(.-)</string>") do strs[#strs + 1] = decodeEntities(s) end
    if #strs >= 2 then
      t = ok(strs[math.floor(#strs / 2) + 1]);      if t then return t, "WebURLsWithTitles" end
    end
  end
  return nil
end

-- Rich-clipboard paste (Recall/YouTube timestamps, any Chromium web-app copy):
-- the plain-text flavor is the skeleton; the HTML flavor carries the anchors.
-- Replace each anchor's visible text with [text](href) — local, instant.
local function stripZeroWidth(s)
  return (s:gsub("\226\128\139", ""):gsub("\239\187\191", ""))
end

local function anchorLinks(html)
  local links = {}
  for attrs, inner in html:gmatch("<[Aa]%s([^>]-)>(.-)</[Aa]>") do
    local href = attrs:match('[Hh][Rr][Ee][Ff]="([^"]-)"')
    if href and href:match("^https?://") then
      local text = stripZeroWidth(decodeEntities(inner:gsub("<[^>]->", "")))
      text = text:gsub("^%s+", ""):gsub("%s+$", "")
      if text ~= "" then links[#links + 1] = { text = text, href = decodeEntities(href) } end
    end
  end
  return links
end

local function applyLinks(text, links)
  local out, consumed = text, 0
  for _, L in ipairs(links) do
    local esc = L.text:gsub("%[", "\\["):gsub("%]", "\\]")
    local link = (L.href:find("[()]") or L.href:find(" ")) and ("<" .. L.href .. ">") or L.href
    local md = "[" .. esc .. "](" .. link .. ")"
    local pat = L.text:gsub("%W", "%%%0")          -- escape as Lua pattern
    local repl = md:gsub("%%", "%%%%")              -- escape as replacement
    local new, n = out:gsub(pat, repl, 1)            -- first occurrence only
    if n > 0 then out, consumed = new, consumed + 1 end
  end
  return out, consumed, #links
end

-- ------------- HTML → Markdown (Google AI / structured rich copies) -------------
-- What Noteplan does internally on ⌘V: Chromium puts the formatted content
-- in the public.html flavor; convert it to markdown locally (instant).
-- Handles: bold/italic/strike/inline-code, links, headings, hr, br,
-- paragraphs, nested ul/ol, tables (th → header separator), code fences.
-- Machine-serialized DOM only — not a general web-HTML parser.

local function emphasisWrap(inner, marker)
  local lead, body, trail = inner:match("^(%s*)(.-)(%s*)$")
  if body == "" then return lead .. trail end
  return lead .. marker .. body .. marker .. trail
end

local function inlinePass(h)
  for _ = 1, 10 do   -- repeat until stable: nested inline elements
    local before = h
    h = h:gsub("<[Cc][Oo][Dd][Ee][^>]*>(.-)</[Cc][Oo][Dd][Ee]>", function(x)
      x = x:gsub("^%s+", ""):gsub("%s+$", ""):gsub("<[^>]->", "")
      if x == "" then return "" end
      local q = x:find("`") and "``" or "`"
      return q .. x .. q
    end)
    h = h:gsub("<[Ss][Tt][Rr][Oo][Nn][Gg][^>]*>(.-)</[Ss][Tt][Rr][Oo][Nn][Gg]>", function(x) return emphasisWrap(x, "**") end)
    h = h:gsub("<[Bb]>(.-)</[Bb]>", function(x) return emphasisWrap(x, "**") end)
    h = h:gsub("<[Bb]%s[^>]->(.-)</[Bb]>", function(x) return emphasisWrap(x, "**") end)
    h = h:gsub("<[Ee][Mm][^>]*>(.-)</[Ee][Mm]>", function(x) return emphasisWrap(x, "*") end)
    h = h:gsub("<[Ii]>(.-)</[Ii]>", function(x) return emphasisWrap(x, "*") end)
    h = h:gsub("<[Ii]%s[^>]->(.-)</[Ii]>", function(x) return emphasisWrap(x, "*") end)
    h = h:gsub("<[Dd][Ee][Ll][^>]*>(.-)</[Dd][Ee][Ll]>", function(x) return emphasisWrap(x, "~~") end)
    h = h:gsub("<[Ss][^>]*>(.-)</[Ss]>", function(x) return emphasisWrap(x, "~~") end)  -- <s> (not <span>: requires space/attrs)
    h = h:gsub("<[Aa]%s([^>]-)>(.-)</[Aa]>", function(attrs, x)
      local href = attrs:match('[Hh][Rr][Ee][Ff]="([^"]*)"')
      local label = stripZeroWidth(decodeEntities(x:gsub("<[^>]->", "")))
        :gsub("^%s+", ""):gsub("%s+$", "")
      if href and href:match("^https?://") and label ~= "" then
        return mdLink(label, decodeEntities(href))
      end
      return x   -- named anchor / no href: keep inner content
    end)
    if h == before then break end
  end
  return h
end

local function cellText(cell)
  cell = decodeEntities(cell:gsub("<[^>]->", ""))
  cell = cell:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  return (cell:gsub("%|", "\\|"))   -- escape pipe: literal | would break the row
end

local function tablePass(h)
  local function convert(t)
    local rows, ncols, hasHeader = {}, 0, false
    for tr in t:gmatch("<[Tt][Rr][^>]*>(.-)</[Tt][Rr]>") do
      local cells = {}
      for cell in tr:gmatch("<[Tt][Dd][^>]*>(.-)</[Tt][Dd]>") do cells[#cells + 1] = cellText(cell) end
      local th = {}
      for cell in tr:gmatch("<[Tt][Hh][^>]*>(.-)</[Tt][Hh]>") do th[#th + 1] = cellText(cell) end
      if #th > 0 then
        hasHeader, ncols = true, #th
        rows[#rows + 1] = "| " .. table.concat(th, " | ") .. " |"
      elseif #cells > 0 then
        rows[#rows + 1] = "| " .. table.concat(cells, " | ") .. " |"
      end
    end
    if #rows == 0 then return "" end
    if hasHeader then
      local sep = {}
      for i = 1, math.max(ncols, 1) do sep[i] = "---" end
      table.insert(rows, 2, "| " .. table.concat(sep, " | ") .. " |")
    end
    return "\n\n" .. table.concat(rows, "\n") .. "\n\n"
  end
  -- tables don't nest in clipboard DOM; convert each (incl. the tbody wrapper case)
  h = h:gsub("<[Tt][Aa][Bb][Ll][Ee][^>]*>(.-)</[Tt][Aa][Bb][Ll][Ee]>", convert)
  return h
end

local function listPass(h)
  local function convertOne(body, ordered)
    local items, n = {}, 0
    for li in body:gmatch("<[Ll][Ii][^>]*>(.-)</[Ll][Ii]>") do
      n = n + 1
      local marker = ordered and (n .. ". ") or "- "
      li = li:gsub("^%s+", ""):gsub("%s+$", "")
      local lines = {}
      for line in (li .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
      for i, line in ipairs(lines) do
        lines[i] = (i == 1) and (marker .. line) or ("  " .. line)
      end
      items[#items + 1] = table.concat(lines, "\n")
    end
    return "\n\n" .. table.concat(items, "\n") .. "\n\n"
  end
  for _ = 1, 20 do   -- innermost list first (nested lists become md lines)
    local before = h
    h = h:gsub("<[Uu][Ll][^>]*>(.-)</[Uu][Ll]>", function(b)
      if b:find("<[Uu][Ll]") or b:find("<[Oo][Ll]") then return nil end   -- not innermost: skip
      return convertOne(b, false)
    end)
    h = h:gsub("<[Oo][Ll][^>]*>(.-)</[Oo][Ll]>", function(b)
      if b:find("<[Uu][Ll]") or b:find("<[Oo][Ll]") then return nil end
      return convertOne(b, true)
    end)
    if h == before then break end
  end
  return h
end

local function htmlToMarkdown(html)
  html = html:gsub("<!%-%-.-%-%->", "")                          -- comments
  html = html:gsub("<[Mm][Ee][Tt][Aa][^>]*>", "")
  -- pull <pre> blocks out; reinsert as fences at the very end
  local pres = {}
  html = html:gsub("<[Pp][Rr][Ee][^>]*>(.-)</[Pp][Rr][Ee]>", function(x)
    pres[#pres + 1] = decodeEntities(x:gsub("<[^>]->", "")):gsub("^%s+", ""):gsub("%s+$", "")
    return "\n\n\194\166PRE" .. #pres .. "\194\166\n\n"
  end)
  html = inlinePass(html)
  html = tablePass(html)
  html = listPass(html)
  -- block structure
  html = html:gsub("<[Hh][Rr][^>]*>", "\n\n---\n\n")
  html = html:gsub("<[Bb][Rr][^>]*>", "\n")
  html = html:gsub("<[Hh]([1-6])[^>]*>(.-)</[Hh][1-6]>", function(lvl, x)
    return "\n\n" .. string.rep("#", tonumber(lvl)) .. " " .. x:gsub("^%s+", ""):gsub("%s+$", "") .. "\n\n"
  end)
  html = html:gsub("<[Pp][^>]*>(.-)</[Pp]>", "\n\n%1\n\n")
  html = html:gsub("</[Dd][Ii][Vv]>", "\n")
  html = html:gsub("<[Dd][Ii][Vv][^>]*>", "\n")
  -- reinsert code fences, strip remaining tags, decode entities
  html = html:gsub("\194\166PRE(%d+)\194\166", function(n)
    return "```\n" .. pres[tonumber(n)] .. "\n```"
  end)
  html = decodeEntities(html:gsub("<[^>]->", ""))
  -- tidy: collapse runs, trim line-ends, collapse redundant emphasis
  html = html:gsub("%*%*%*%*+", "**")
  html = html:gsub("[ \t]+\n", "\n")
  html = html:gsub("\n\n\n+", "\n\n")
  return (html:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- structural HTML = rich formatting that plain text loses → full conversion;
-- link-only HTML (Recall) keeps the anchor-surgery path (plain text is the
-- better skeleton there: Chromium's own line breaks/punctuation).
local function isStructural(html)
  return html:find("<[Tt][Aa][Bb][Ll][Ee]") or html:find("<[Ss][Tt][Rr][Oo][Nn][Gg]")
      or html:find("<[Bb][%s>]") or html:find("<[Ee][Mm][%s>]") or html:find("<[Ii][%s>]")
      or html:find("<[Uu][Ll][%s>]") or html:find("<[Oo][Ll][%s>]") or html:find("<[Pp][Rr][Ee]")
      or html:find("<[Hh][1-6]") or html:find("<[Hh][Rr][%s/>]") or html:find("<[Dd][Ee][Ll]")
end

-- ------------------------- delivery -------------------------

local fetching = false  -- one fetch at a time
local queued    = false  -- a press arrived mid-flight → one deferred delivery when ready
local titleCache = {}    -- url -> { md = …, at = ms } (10 min TTL)

-- Write text directly into the focused editor via Accessibility. The clean
-- primitive: no keystrokes, no clipboard, no modifier/layout coupling.
local function axInsert(text)
  local okax, ax = pcall(require, "hs.axuielement")
  if not okax then return false, "no hs.axuielement" end
  local okel, el = pcall(function()
    return ax.systemWideElement():attributeValue("AXFocusedUIElement")
  end)
  if not okel or not el then return false, "no focused element" end
  local okset, err = pcall(function() el:setAttributeValue("AXSelectedText", text) end)
  if not okset then return false, err end
  return true
end

local function deliverMd(md, url, source, t0)
  titleCache[url] = { md = md, at = nowMs() }

  local ok, err = axInsert(md)
  if ok then
    fetching = false
    logf(("PASTED-ax src=%s host=%s %dms | %s"):format(source, hostname(url), nowMs() - t0, md:sub(1, 90)))
    if queued then  -- press(es) arrived while fetching: deliver once more
      queued = false
      hs.timer.doAfter(0.2, function()
        guard("queued-ax", function()
          axInsert(md)
          logf("PASTED-ax (queued repeat) | " .. md:sub(1, 60))
        end)
      end)
    end
    return
  end

  -- Fallback (AX not settable in target app): clipboard swap + ⌘V after
  -- modifier release. Preserved clipboard, race-delayed paste.
  logf("AX insert failed (" .. tostring(err) .. ") → clipboard fallback")
  local saved = hs.pasteboard.readString()
  hs.pasteboard.setContents(md)
  hs.timer.doAfter(0.05, function()
    waitModsThen(function()
      hs.eventtap.keyStroke({"cmd"}, "v", 0)
      fetching = false
      logf(("PASTED-fallback src=%s host=%s %dms | %s"):format(source, hostname(url), nowMs() - t0, md:sub(1, 90)))
      hs.timer.doAfter(1.5, function()
        guard("restore", function() hs.pasteboard.setContents(saved) end)
      end)
    end, "paste")
  end)
end

local function fetchAndPaste(url, t0, deliver)
  local tmp = "/tmp/hs-mdlink-page-" .. tostring(t0) .. ".html"
  hs.task.new("/usr/bin/curl", function(code)
    guard("curl", function()
      local title = ""
      if code == 0 then
        local f = io.open(tmp, "r")
        if f then
          local data = f:read("*a"); f:close()
          local m = data and data:match("<[Tt][Ii][Tt][Ll][Ee][^>]*>(.-)</[Tt][Ii][Tt][Ll][Ee]>")
          if m then title = cleanTitle(decodeEntities(m)) end
        end
      end
      os.remove(tmp)
      if title == "" then title = hostname(url) end   -- never hang, never bare-URL
      local md = mdLink(title, url)
      local src = (code == 0) and "fetch" or ("fetch-fail:" .. tostring(code))
      if deliver then deliverMd(md, url, src, t0)
      else fetching = false; logf(("RESOLVE(no-paste) src=%s host=%s %dms | %s"):format(src, hostname(url), nowMs() - t0, md:sub(1, 90))) end
    end)
  end, { "-sL", "--compressed", "--max-time", "3", "-A", UA, "-o", tmp, url }):start()
end

-- ------------------------- test hook (terminal, no keystrokes) -------------------------

MDLink = {}
-- read-only: convert the current rich clipboard exactly as ⌘⇧V would
function MDLink.richPreview()
  local d = hs.pasteboard.readAllData()
  local html = d["public.html"] or d["text/html"]
  if type(html) ~= "string" then return nil, "no html flavor" end
  local links = anchorLinks(html)
  if #links == 0 then return nil, "no links" end
  return applyLinks(hs.pasteboard.readString() or "", links)
end

-- pure: convert arbitrary (html, plainText) — used by richPreview and tests
function MDLink.richConvert(html, text)
  local links = anchorLinks(html)
  if #links == 0 then return nil, "no links" end
  return applyLinks(text, links)
end

-- pure: full structural HTML→markdown (Google AI test hook)
function MDLink.richFull(html)
  if not isStructural(html) then return nil, "not structural" end
  return htmlToMarkdown(html)
end

function MDLink.test(url, deliver)
  if fetching then logf("TEST ignored: fetch in flight") return end
  fetching = true
  if deliver == nil then deliver = false end
  local t0 = nowMs()
  logf("TEST " .. url .. (deliver and " (deliver)" or " (resolve only)"))
  fetchAndPaste(url, t0, deliver)
end

-- ------------------------- the hotkey -------------------------

mdlinkHotkey = hs.hotkey.new({"cmd", "shift"}, "v", function()
  local t0 = nowMs()
  local d = hs.pasteboard.readAllData()

  local url
  if type(d["public.url"]) == "string" then url = d["public.url"]:match("^%s*(https?://%S+)%s*$") end
  if not url then
    local text = hs.pasteboard.readString() or ""
    url = text:match("^%s*(https?://%S+)%s*$")  -- exactly one plain URL, else forward
  end

  if not url then
    -- STRUCTURAL rich clipboard (Google AI etc.): full HTML→markdown
    -- conversion — bold/tables/lists/headings survive, like Noteplan's ⌘V
    local html = d["public.html"] or d["text/html"]
    if type(html) == "string" and isStructural(html) then
      local t1 = nowMs()
      local md = htmlToMarkdown(html)
      if md and #md > 0 then
        local ok = axInsert(md)
        logf(("PASTED-ax src=html2md %d bytes → %d bytes %dms"):format(#html, #md, nowMs() - t1))
        if ok then return end
        logf("html2md AX failed → clipboard fallback")
        local saved = hs.pasteboard.readString()
        hs.pasteboard.setContents(md)
        hs.timer.doAfter(0.05, function()
          waitModsThen(function()
            hs.eventtap.keyStroke({"cmd"}, "v", 0)
            logf("PASTED-fallback src=html2md " .. (nowMs() - t0) .. "ms")
            hs.timer.doAfter(1.5, function()
              guard("restore", function() hs.pasteboard.setContents(saved) end)
            end)
          end, "paste")
        end)
        return
      end
    end
    -- link-only rich clipboard (e.g. Recall transcripts with YouTube
    -- timestamps): convert anchors to markdown locally — Noteplan-style
    local html = d["public.html"] or d["text/html"]
    if type(html) == "string" and html:find("[Hh][Rr][Ee][Ff]=") then
      local links = anchorLinks(html)
      if #links > 0 then
        local text = hs.pasteboard.readString() or ""
        local md, consumed, total = applyLinks(text, links)
        if consumed > 0 then
          local ok = axInsert(md)
          logf(("PASTED-ax src=richlinks %d/%d links %dms"):format(consumed, total, nowMs() - t0))
          if ok then return end
          logf("richlinks AX failed → clipboard fallback")
          -- clipboard fallback: same race-safe path as deliverMd
          local saved = hs.pasteboard.readString()
          hs.pasteboard.setContents(md)
          hs.timer.doAfter(0.05, function()
            waitModsThen(function()
              hs.eventtap.keyStroke({"cmd"}, "v", 0)
              logf("PASTED-fallback src=richlinks " .. (nowMs() - t0) .. "ms")
              hs.timer.doAfter(1.5, function()
                guard("restore", function() hs.pasteboard.setContents(saved) end)
              end)
            end, "paste")
          end)
          return
        end
      end
    end
    -- not rich: insert the clipboard text directly (small text) or native ⌘V
    local text = hs.pasteboard.readString() or ""
    if text ~= "" and #text <= 2000 then
      local ok = axInsert(text)
      if ok then logf("FORWARD-ax (text inserted) " .. (nowMs() - t0) .. "ms") return end
    end
    waitModsThen(function()
      hs.eventtap.keyStroke({"cmd"}, "v", 0)
      logf("FORWARD native ⌘V " .. (nowMs() - t0) .. "ms")
    end, "forward")
    return
  end

  local title, src = instantTitle(d, url)
  if title then
    deliverMd(mdLink(title, url), url, "instant:" .. src, t0)   -- 0 network, like Noteplan
    return
  end

  local c = titleCache[url]
  if c and (nowMs() - c.at) < 600000 then
    deliverMd(c.md, url, "cache", t0)                            -- seen before → 0ms
  elseif fetching then
    queued = true
    logf("PRESS during fetch → queued (one delivery when ready)")
  else
    fetching = true
    hs.alert.show("🔗 " .. hostname(url), 0.4)                   -- visible wait indicator
    logf("HOTKEY url=" .. hostname(url) .. " → background fetch (3s cap)")
    fetchAndPaste(url, t0, true)
  end
end)

-- ------------------------- outline navigator (⌘⇧O) -------------------------
-- Noteplan-style document structure for FSNotes: summon a fuzzy-searchable
-- overlay of the note's markdown headings; selecting one jumps the editor
-- there (AXSelectedTextRange — selects the heading line and scrolls; the
-- same AX primitive as our text insertion: no synthetic keystrokes).
-- NB: AX text offsets are UTF-16 units, Lua strings are UTF-8 bytes (Cyrillic
-- notes!) — offsets are tracked in UTF-16 explicitly below.

local function utf16len(s)
  local ok, n = pcall(function()
    local count = 0
    for _, cp in utf8.codes(s) do count = count + (cp >= 0x10000 and 2 or 1) end
    return count
  end)
  return ok and n or #s   -- invalid UTF-8: byte length is the least-wrong guess
end

local function outlineEditor()
  local axok, ax = pcall(require, "hs.axuielement")
  if not axok then return nil end
  local app = hs.application.get(FSNOTES_BUNDLE_ID)
  local win = app and app:focusedWindow()
  if not win then return nil end
  local root = ax.windowElement(win)
  local best, bestLen = nil, -1
  local function walk(e, depth)
    if depth > 12 then return end
    local okr, role = pcall(function() return e:attributeValue("AXRole") end)
    if okr and role == "AXTextArea" then
      local okv, v = pcall(function() return e:attributeValue("AXValue") end)
      if okv and type(v) == "string" and #v > bestLen then best, bestLen = e, #v end
    end
    local okc, kids = pcall(function() return e:attributeValue("AXChildren") end)
    if okc and type(kids) == "table" then for _, k in ipairs(kids) do walk(k, depth + 1) end end
  end
  pcall(walk, root, 0)
  return best   -- the biggest text area in the window = the note editor
end

-- Lua patterns have no {m,n} quantifier (learned live: #{1,6} is literal) —
-- use #+ and clamp the level. Code fences are skipped.
local function parseHeadings(text)
  local heads = {}
  local u16, inFence, lineNo = 0, false, 0
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    lineNo = lineNo + 1
    if line:match("^%s*```") then inFence = not inFence end
    if not inFence then
      local hashes, title = line:match("^(#+)%s+(.-)%s*$")
      if hashes and #hashes <= 6 and title ~= "" then
        heads[#heads + 1] = {
          level = #hashes, text = title, line = lineNo,
          u16loc = u16, u16len = utf16len(line),
        }
      end
    end
    u16 = u16 + utf16len(line) + 1
  end
  return heads
end

local outlineEditorEl, outlineRows

outlineChooser = hs.chooser.new(function(choice)
  if not choice or not choice._h then return end   -- Esc / stale
  local h, el = choice._h, outlineEditorEl
  if el then
    pcall(function()
      el:setAttributeValue("AXSelectedTextRange", { location = h.u16loc, length = h.u16len })
    end)
    logf(("OUTLINE jump L%d H%d %q u16=%d"):format(h.line, h.level, h.text:sub(1, 50), h.u16loc))
  end
end)
outlineChooser:queryChangedCallback(function(q)
  guard("outline-filter", function()
    if q == "" then outlineChooser:choices(outlineRows); return end
    local filtered = {}
    local ql = q:lower()
    for _, row in ipairs(outlineRows) do      -- subsequence fuzzy match
      local txt, i, j = row.text:lower(), 1, 1
      while i <= #ql and j <= #txt do
        if ql:sub(i, i) == txt:sub(j, j) then i = i + 1 end
        j = j + 1
      end
      if i > #ql then filtered[#filtered + 1] = row end
    end
    outlineChooser:choices(filtered)
  end)
end)
outlineChooser:placeholderText("Jump to heading…  (Esc to cancel)")
outlineChooser:rows(15)
outlineChooser:bgDark(true)

local function outlineShow()
  local t0 = nowMs()
  local el = outlineEditor()
  if not el then hs.alert.show("Outline: no editor found", 0.6); logf("OUTLINE: editor not found") return end
  local text = el:attributeValue("AXValue")
  local heads = parseHeadings(text or "")
  if #heads == 0 then hs.alert.show("No headings in this note", 0.6); logf("OUTLINE: 0 headings " .. (nowMs() - t0) .. "ms") return end
  outlineEditorEl = el
  outlineRows = {}
  for _, h in ipairs(heads) do
    outlineRows[#outlineRows + 1] = {
      text = string.rep("    ", h.level - 1) .. h.text,
      subText = ("H%d · line %d"):format(h.level, h.line),
      _h = h,
    }
  end
  outlineChooser:choices(outlineRows)
  outlineChooser:query("")
  outlineChooser:show()
  logf(("OUTLINE shown: %d headings, parse %dms"):format(#heads, nowMs() - t0))
end

outlineHotkey = hs.hotkey.new({"cmd", "shift"}, "o", function() guard("outline-show", outlineShow) end)

-- terminal/test hooks (no keystrokes): MDOutline.probe() / .show() / .jumpLast()
MDOutline = {}
function MDOutline.probe()
  local el = outlineEditor()
  if not el then return "no editor" end
  local heads = parseHeadings(el:attributeValue("AXValue") or "")
  local first = heads[1] and ('L' .. heads[1].line .. " " .. heads[1].text) or "-"
  local last = heads[#heads] and ('L' .. heads[#heads].line .. " " .. heads[#heads].text) or "-"
  return #heads .. " headings | first: " .. first .. " | last: " .. last
end
function MDOutline.show() outlineShow() end
function MDOutline.jumpLast()
  local el = outlineEditor()
  if not el then return "no editor" end
  local heads = parseHeadings(el:attributeValue("AXValue") or "")
  local h = heads[#heads]
  if not h then return "no headings" end
  el:setAttributeValue("AXSelectedTextRange", { location = h.u16loc, length = h.u16len })
  local sel = el:attributeValue("AXSelectedText")
  local vis = el:attributeValue("AXVisibleCharacterRange")
  local visible = vis and vis.location <= h.u16loc and (h.u16loc + h.u16len) <= (vis.location + vis.length)
  return string.format("jumped L%d %q | sel=%q | visible after: %s", h.line, h.text:sub(1, 40),
                       (sel or "?"):sub(1, 30), tostring(visible))
end

-- ------------------------- hotkey scoping -------------------------

local fsNotesActive = false
local function syncHotkey()
  local front = hs.application.frontmostApplication()
  local active = (front and front:bundleID() == FSNOTES_BUNDLE_ID) or false
  if active ~= fsNotesActive then
    logf("frontmost → " .. (active and "FSNotes (hotkeys ENABLED: ⌘⇧V ⌘⇧O)" or
         ((front and front:bundleID() or "?") .. " (hotkeys disabled)")))
    fsNotesActive = active
  end
  if active then
    mdlinkHotkey:enable()
    outlineHotkey:enable()
  else
    mdlinkHotkey:disable()
    outlineHotkey:disable()
  end
end

appWatcher = hs.application.watcher.new(function(_, event, app)
  if event == hs.application.watcher.activated and app then syncHotkey() end
end)
appWatcher:start()

syncHotkey()
logf("=== config loaded: recorder + hotkeys (⌘⇧V md-paste, ⌘⇧O outline) ===")
