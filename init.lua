local ax = hs.axuielement

-- Allow diagnostic/control via AppleScript while debugging Notion AX changes.
if hs.allowAppleScript then hs.allowAppleScript(true) end

local MENU_WAIT_SECONDS = 1.2
local APPLY_WAIT_SECONDS = 2.0
local NEXT_POLL_SECONDS = 0.25
local NEXT_POLL_LIMIT = 40
local MAX_PAGES_PER_RUN = 1500

local batch = nil

local DEBUG_LOG_PATH = "/tmp/notion-offline-debug.log"


local function debugLog(message)
    local now = 0
    if hs.timer and hs.timer.secondsSinceEpoch then
        now = hs.timer.secondsSinceEpoch()
    end
    local line = string.format("%.3f %s\n", now, tostring(message))
    print("[NotionOffline] " .. tostring(message))
    pcall(function()
        local fh = assert(io.open(DEBUG_LOG_PATH, "a"))
        fh:write(line)
        fh:close()
    end)
end

local generation = 0
local statsAlertId = nil


-- ============================================================
-- ACCESSIBILITY HELPERS
-- ============================================================

local function getAttr(element, name)
    if not element then return nil end
    local ok, value = pcall(function() return element:attributeValue(name) end)
    if ok then return value end -- Preserve boolean false (not just truthy values).
end


local function findElement(element, matcher)
    if not element then return nil end
    if matcher(element) then return element end
    for _, child in ipairs(getAttr(element, "AXChildren") or {}) do
        local found = findElement(child, matcher)
        if found then return found end
    end
end


local function normalizeLabel(text)
    if type(text) ~= "string" then return "" end
    -- Notion may use either a Unicode ellipsis or three ASCII dots.
    return (text:gsub("…", "..."):lower())
end


local function hasLabel(element, label)
    local want = normalizeLabel(label)
    for _, name in ipairs({ "AXDescription", "AXTitle", "AXValue", "AXPlaceholderValue" }) do
        if normalizeLabel(getAttr(element, name)) == want then return true end
    end
    return false
end


local function labelContains(element, fragment)
    local want = normalizeLabel(fragment)
    if want == "" then return false end
    for _, name in ipairs({ "AXDescription", "AXTitle", "AXValue", "AXPlaceholderValue" }) do
        local value = normalizeLabel(getAttr(element, name))
        if value ~= "" and value:find(want, 1, true) then return true end
    end
    return false
end


local function isWithin(element, ancestor)
    for _ = 1, 100 do
        if not element then return false end
        if element == ancestor then return true end
        element = getAttr(element, "AXParent")
    end
    return false
end


local function containsFrame(outer, inner)
    return outer and inner and inner.w > 0 and inner.h > 0
        and inner.x >= outer.x and inner.y >= outer.y
        and inner.x + inner.w <= outer.x + outer.w + 1
        and inner.y + inner.h <= outer.y + outer.h + 1
end


local function visibleFrame(element, window)
    local frame = getAttr(element, "AXFrame")
    if not containsFrame(getAttr(window, "AXFrame"), frame)
        or getAttr(element, "AXEnabled") == false then return nil end
    local ancestor = element
    for _ = 1, 100 do
        if not ancestor then return nil end
        if getAttr(ancestor, "AXHidden") == true
            or getAttr(ancestor, "AXVisible") == false then return nil end
        if ancestor == window then return frame end
        ancestor = getAttr(ancestor, "AXParent")
    end
end


-- A read-only hit test confirms that the point belongs to the current document.
local function exposedAt(element, point)
    local ok, hit = pcall(function()
        return ax.systemWideElement():elementAtPosition(point)
    end)
    if not ok or not hit then return false end
    if isWithin(hit, element) then return true end
    -- Electron can return a cached child or the AXWebArea when the test point
    -- moves. Its leaf result is not a reliable control identifier. Require the
    -- same document; callers identify the control by live peek/panel scope,
    -- frame, label, menu focus, and (for the fallback) the visible switch.
    local web = element
    for _ = 1, 100 do
        if not web then return false end
        if getAttr(web, "AXRole") == "AXWebArea" then return isWithin(hit, web) end
        web = getAttr(web, "AXParent")
    end
    return false
end


local function exposed(element, window)
    local f = visibleFrame(element, window)
    return f and exposedAt(element, { x = f.x + f.w / 2, y = f.y + f.h / 2 })
end


local function getNotionWindow()
    -- Do not require Notion to be frontmost. Alerts, Hammerspoon, or other
    -- apps briefly taking focus used to abort the batch mid-advance.
    local apps = hs.application.applicationsForBundleID("notion.id") or {}
    local app = apps[1]
    if not app then return nil end
    local axApp = ax.applicationElement(app)
    local focused = getAttr(axApp, "AXFocusedWindow")
    if focused then return focused end
    local windows = getAttr(axApp, "AXWindows") or {}
    return windows[1]
end


local function getActiveWebArea(window)
    if not window then return nil end
    local apps = hs.application.applicationsForBundleID("notion.id") or {}
    local app = apps[1]
    if not app then return nil end
    local focus = getAttr(ax.applicationElement(app), "AXFocusedUIElement")
    for _ = 1, 100 do
        if not focus or focus == window then break end
        if getAttr(focus, "AXRole") == "AXWebArea"
            and getAttr(focus, "AXTitle") ~= "Tab Bar"
            and visibleFrame(focus, window) then return focus end
        focus = getAttr(focus, "AXParent")
    end
    -- AXFocused is also true on inactive Electron tabs. Use actual visibility
    -- and require a unique content web area if focus is in native tab chrome.
    local candidates = {}
    findElement(window, function(e)
        if getAttr(e, "AXRole") == "AXWebArea"
            and getAttr(e, "AXTitle") ~= "Tab Bar" and exposed(e, window) then
            candidates[#candidates + 1] = e
        end
        return false
    end)
    if #candidates == 0 then return nil end
    if #candidates == 1 then return candidates[1] end
    -- Multiple Electron tabs can remain exposed. Prefer the web area that
    -- currently hosts a visible peek / full-page link / Actions control.
    local function score(web)
        local points = 0
        if findElement(web, function(e) return hasLabel(e, "Side Peek") and visibleFrame(e, window) end) then
            points = points + 8
        end
        if findElement(web, function(e) return hasLabel(e, "Open in full page") and visibleFrame(e, window) end) then
            points = points + 4
        end
        if findElement(web, function(e) return hasLabel(e, "Actions") and visibleFrame(e, window) end) then
            points = points + 2
        end
        local f = visibleFrame(web, window)
        if f then points = points + math.min(f.w * f.h, 1e7) / 1e7 end
        return points
    end
    table.sort(candidates, function(a, b) return score(a) > score(b) end)
    print(string.format("Active web area: chose 1 of %d visible candidates", #candidates))
    return candidates[1]
end


local function getPeekRoot(window)
    local web = getActiveWebArea(window)
    local sidePeek = findElement(web, function(e)
        return hasLabel(e, "Side Peek") and visibleFrame(e, window)
    end)
    if sidePeek then return sidePeek end
    -- The redesigned actions panel is ALSO an AXApplicationDialog. A centre
    -- peek must contain its own full-page link, not the actions search field.
    return findElement(web, function(e)
        return getAttr(e, "AXSubrole") == "AXApplicationDialog"
            and visibleFrame(e, window)
            and findElement(e, function(c) return hasLabel(c, "Open in full page") end)
            and not findElement(e, function(c) return hasLabel(c, "Search actions…") end)
    end)
end


local function findActionsButton(window)
    local peek = getPeekRoot(window)
    if not peek then return nil end
    local candidates = {}
    findElement(peek, function(e)
        if hasLabel(e, "Actions") and exposed(e, window) then
            candidates[#candidates + 1] = e
        end
        return false
    end)
    if #candidates == 0 then return nil end
    if #candidates > 1 then
        table.sort(candidates, function(a, b)
            local fa, fb = getAttr(a, "AXFrame"), getAttr(b, "AXFrame")
            if not fa then return false end
            if not fb then return true end
            if fa.x ~= fb.x then return fa.x > fb.x end
            return fa.y < fb.y
        end)
        print(string.format("Actions button: chose rightmost of %d visible peek candidates", #candidates))
    end
    local best = candidates[1]
    local f = getAttr(best, "AXFrame")
    if f then
        print(string.format("Actions button: role=%s frame=%.0f,%.0f %.0fx%.0f",
            tostring(getAttr(best, "AXRole")), f.x, f.y, f.w, f.h))
    end
    return best
end


local function elementTextBlob(element)
    local parts = {}
    for _, name in ipairs({
        "AXDescription", "AXTitle", "AXValue", "AXPlaceholderValue",
        "AXHelp", "AXRoleDescription"
    }) do
        local value = getAttr(element, name)
        if type(value) == "string" and value ~= "" then
            parts[#parts + 1] = value
        end
    end
    return normalizeLabel(table.concat(parts, " "))
end


local function looksLikeOfflineLabel(element)
    local blob = elementTextBlob(element)
    if blob == "" then return false end
    if blob:find("available offline", 1, true) then return true end
    -- Some Notion builds split or slightly reword the row text.
    if blob:find("offline", 1, true) and blob:find("available", 1, true) then return true end
    return false
end


local function findOfflineItem(window)
    local web = getActiveWebArea(window)
    if not web then return nil, "active web area missing" end

    local search = findElement(web, function(e)
        local role = getAttr(e, "AXRole")
        return (role == "AXComboBox" or role == "AXTextField" or role == "AXSearchField")
            and labelContains(e, "Search actions") and visibleFrame(e, window)
    end)

    local panel = nil
    if search then
        panel = getAttr(search, "AXParent")
        while panel and panel ~= web do
            if getAttr(panel, "AXSubrole") == "AXApplicationDialog" then break end
            panel = getAttr(panel, "AXParent")
        end
        if not panel or panel == web then panel = nil end
    end

    -- Fallback: actions popover dialog (not the peek dialog that has Open in full page).
    if not panel then
        panel = findElement(web, function(e)
            if getAttr(e, "AXSubrole") ~= "AXApplicationDialog" then return false end
            if not visibleFrame(e, window) then return false end
            if findElement(e, function(c) return hasLabel(c, "Open in full page") end) then
                return false
            end
            local f = getAttr(e, "AXFrame")
            -- Actions popover is a narrow floating panel.
            return f and f.w >= 160 and f.w <= 360 and f.h >= 120
        end)
    end
    if not panel then
        return nil, search and "Actions dialog ancestor missing" or "visible Actions panel missing"
    end

    local app = hs.application.frontmostApplication()
    local focus = app and getAttr(ax.applicationElement(app), "AXFocusedUIElement")
    local focusInPanel = isWithin(focus, panel)

    local scope = findElement(panel, function(e)
        return (getAttr(e, "AXRole") == "AXList" or labelContains(e, "Actions collection"))
            and visibleFrame(e, window)
    end) or panel

    local label = findElement(scope, function(e)
        return looksLikeOfflineLabel(e) and visibleFrame(e, window)
    end)
    if not label then
        -- Last chance: any descendant text in the panel.
        label = findElement(panel, function(e)
            return looksLikeOfflineLabel(e) and visibleFrame(e, window)
        end)
    end
    if not label then return nil, "Available offline label missing" end

    local row = label
    local rejected = {}
    while row and row ~= panel do
        local f = visibleFrame(row, window)
        local inScope = f and containsFrame(getAttr(scope, "AXFrame") or getAttr(panel, "AXFrame"), f)
        local hit = f and exposed(row, window)
        -- Accept the redesigned generic row/container. Electron hit-testing is
        -- flaky, so allow a visible in-scope row when the panel already has focus.
        if f and inScope and f.h >= 16 and f.h <= 80 and f.w >= 80
            and f.w / f.h >= 2.5 and f.w / f.h <= 40
            then -- geometry+inScope enough; Electron hit tests are unreliable
            print(string.format(
                "Offline row: role=%s frame=%.0fx%.0f focusInPanel=%s hit=%s",
                tostring(getAttr(row, "AXRole")), f.w, f.h, tostring(focusInPanel), tostring(hit)))
            return row
        end
        rejected[#rejected + 1] = string.format("%s frame=%s inScope=%s hit=%s focus=%s",
            tostring(getAttr(row, "AXRole")), f and string.format("%.0fx%.0f", f.w, f.h) or "hidden",
            tostring(inScope), tostring(hit), tostring(focusInPanel))
        row = getAttr(row, "AXParent")
    end

    local parent = getAttr(label, "AXParent")
    if parent and visibleFrame(parent, window) then
        print("Offline row: falling back to label parent " .. tostring(getAttr(parent, "AXRole")))
        return parent
    end
    if visibleFrame(label, window) then
        print("Offline row: falling back to label element " .. tostring(getAttr(label, "AXRole")))
        return label
    end
    return nil, "offline row rejected: " .. table.concat(rejected, "; ")
end


-- Locate with Accessibility, but open/activate with a single real mouse click.
local function clickLikeUser(element, window)
    if not exposed(element, window) then return false end
    local frame = visibleFrame(element, window)
    local point = { x = frame.x + frame.w / 2, y = frame.y + frame.h / 2 }
    hs.mouse.absolutePosition(point)
    hs.eventtap.leftClick(point, 100000)
    return true
end


local function urlValue(element)
    local value = getAttr(element, "AXURL")
    if type(value) == "table" then value = value.url end
    if type(value) == "string" then return value end
end


local function pageIdFromUrl(url)
    if type(url) ~= "string" or url == "" then return nil end
    local path = url:match("/p/([^?#]+)") or url
    local id = path:match("(%x+%-%x+%-%x+%-%x+%-%x+)$")
        or path:match("(%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x)%f[%X]")
    if not id then
        id = url:match("(%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x)")
    end
    if not id then return nil end
    id = id:gsub("%-", ""):lower()
    if #id == 32 then return "page:" .. id end
end


local function peekHeadingSignature(peek)
    if not peek then return nil end
    local parts = {}
    findElement(peek, function(e)
        if getAttr(e, "AXRole") == "AXHeading" then
            for _, name in ipairs({ "AXTitle", "AXValue" }) do
                local value = getAttr(e, name)
                if type(value) == "string" and value ~= "" and #value < 200 then
                    parts[#parts + 1] = value
                end
            end
        end
        return false
    end)
    if #parts == 0 then return nil end
    return "heading:" .. table.concat(parts, "|"):sub(1, 240)
end


local function peekContentFingerprint(peek)
    if not peek then return nil end
    local bits = {}
    findElement(peek, function(e)
        local role = getAttr(e, "AXRole")
        if role == "AXHeading" or role == "AXStaticText" or role == "AXTextArea" then
            for _, name in ipairs({ "AXTitle", "AXValue" }) do
                local value = getAttr(e, name)
                if type(value) == "string" and value ~= "" and #value < 160 then
                    bits[#bits + 1] = role .. ":" .. value
                    break
                end
            end
        end
        return #bits >= 8
    end)
    if #bits == 0 then return nil end
    return "fp:" .. table.concat(bits, "||"):sub(1, 400)
end


local function describePage(window)
    local web = getActiveWebArea(window)
    local peek = getPeekRoot(window)
    local link = peek and findElement(peek, function(e) return hasLabel(e, "Open in full page") end)
    return {
        peekId = pageIdFromUrl(urlValue(link)),
        heading = peekHeadingSignature(peek),
        fingerprint = peekContentFingerprint(peek),
        webId = pageIdFromUrl(urlValue(web)),
        hasPeek = peek ~= nil,
        hasActions = findActionsButton(window) ~= nil,
    }
end


local function getPageSignature(window)
    local info = describePage(window)
    -- Prefer peek page id, then heading, then content fingerprint, then web id.
    return info.peekId or info.heading or info.fingerprint or info.webId
end


local function pageChanged(before, after)
    if not before or not after then return false end
    if before.peekId and after.peekId and before.peekId ~= after.peekId then return true, "peekId" end
    if before.heading and after.heading and before.heading ~= after.heading then return true, "heading" end
    if before.fingerprint and after.fingerprint and before.fingerprint ~= after.fingerprint then
        return true, "fingerprint"
    end
    -- webId alone is unreliable (often the database). Only use if peek signals absent.
    if not before.peekId and not after.peekId and not before.heading and not after.heading
        and before.webId and after.webId and before.webId ~= after.webId then
        return true, "webId"
    end
    return false, nil
end


-- ============================================================
-- READ THE AVAILABLE-OFFLINE SWITCH (NO ACTIONS IN THIS SECTION)
-- ============================================================

local function booleanState(value)
    if value == true or value == 1 or value == "1" or value == "true" or value == "on" then return true end
    if value == false or value == 0 or value == "0" or value == "false" or value == "off" then return false end
end


local function accessibilityState(row)
    local state, source, conflict
    findElement(row, function(e)
        local value = booleanState(getAttr(e, "AXChecked"))
        local attribute = "AXChecked"
        local role, subrole = getAttr(e, "AXRole"), getAttr(e, "AXSubrole")
        if value == nil and (role == "AXCheckBox" or role == "AXSwitch" or subrole == "AXSwitch") then
            value = booleanState(getAttr(e, "AXValue"))
            attribute = "AXValue"
        end
        -- AXSelected on menu rows means keyboard highlight, NOT offline state.
        if value ~= nil then
            if state ~= nil and state ~= value then conflict = true end
            state, source = value, tostring(role) .. "." .. attribute
        end
        return false
    end)
    if conflict then return nil, "conflicting Accessibility states" end
    return state, source
end


local function isOfflineEnabled(row, window)
    if not exposed(row, window) then return nil, "offline row is not visible" end
    local state, source = accessibilityState(row)
    if state ~= nil or source then return state, source end
    local f = visibleFrame(row, window)
    -- September 2026 layout: 28x16 switch in a 26pt row, with a 7pt right
    -- inset. All coordinates scale from the validated current row, not screen.
    local switchW, inset = f.h * 28 / 26, f.h * 7 / 26
    local left = f.x + f.w - inset - switchW
    if not exposedAt(row, { x = left + switchW / 2, y = f.y + f.h / 2 }) then
        return nil, "switch is covered"
    end
    local screen = hs.screen.find(f)
    if not screen or not containsFrame(screen:fullFrame(), f) then
        return nil, "offline row crosses a screen boundary"
    end
    local image = screen:snapshot(screen:absoluteToLocal(f))
    if not image then return nil, "screen capture unavailable" end
    local bitmap = image:bitmapRepresentation({ w = math.floor(f.w), h = math.floor(f.h) }, false)
    if not bitmap then return nil, "screen bitmap unavailable" end
    local onVotes, offVotes = 0, 0
    local function white(c)
        return c and c.red and c.green and c.blue
            and math.min(c.red, c.green, c.blue) > 0.92
    end
    local function blue(c)
        return c and c.red and c.green and c.blue and c.blue > 0.65
            and c.blue > c.red + 0.15 and c.blue > c.green + 0.08
    end
    local function gray(c)
        return c and c.red and c.green and c.blue
            and math.max(c.red, c.green, c.blue) - math.min(c.red, c.green, c.blue) < 0.06
            and c.red > 0.65 and c.red < 0.90
    end
    for _, dy in ipairs({ -0.07, 0, 0.07 }) do
        for _, dx in ipairs({ -0.04, 0, 0.04 }) do
            local function sample(position)
                return bitmap:colorAt(hs.geometry.point(
                    math.floor(f.w - inset - switchW + switchW * (position + dx)),
                    math.floor(f.h * (0.5 + dy))))
            end
            local l, r = sample(0.25), sample(0.75)
            if blue(l) and white(r) then onVotes = onVotes + 1 end
            if white(l) and gray(r) then offVotes = offVotes + 1 end
        end
    end
    local detail = string.format("visual ON=%d/9 OFF=%d/9", onVotes, offVotes)
    if onVotes >= 6 and offVotes == 0 then return true, detail end
    if offVotes >= 6 and onVotes == 0 then return false, detail end
    return nil, detail .. "; unrecognized switch appearance"
end


-- ============================================================
-- PROCESS EXACTLY ONE PAGE
-- ============================================================

local function processOnePage(shouldContinue, onComplete, onError)
    if not shouldContinue() then return end
    local window = getNotionWindow()
    local web = getActiveWebArea(window)
    local originalURL = urlValue(web)
    local actionsButton = findActionsButton(window)
    if not actionsButton then
        for _ = 1, 6 do
            hs.timer.usleep(200000)
            window = getNotionWindow() or window
            web = getActiveWebArea(window) or web
            originalURL = urlValue(web)
            actionsButton = findActionsButton(window)
            if actionsButton then break end
        end
    end
    if not actionsButton then onError("visible page Actions button not found"); return end

    local function sameContext()
        local current = getNotionWindow()
        local active = getActiveWebArea(current)
        return current == window and active == web and urlValue(active) == originalURL
    end
    local function closeMenu()
        -- Always attempt Escape after the menu was opened. Requiring a successful
        -- offline-row lookup left the popover stranded when discovery failed.
        hs.eventtap.keyStroke({}, "escape", 100000)
        if batch then batch.menuOpen = false end
    end
    local function fail(message)
        closeMenu()
        onError(message)
    end
    local function inspectRow()
        if not sameContext() then return nil, nil, "active window, tab or page changed" end
        local row, lookupReason = findOfflineItem(window)
        if not row then return nil, nil, "Available offline not found: " .. tostring(lookupReason) end
        local ok, state, detail = pcall(isOfflineEnabled, row, window)
        if not ok then return row, nil, "offline state read failed: " .. tostring(state) end
        print(string.format("Offline row %s; %s; state=%s", tostring(getAttr(row, "AXRole")),
            tostring(detail), state == nil and "UNKNOWN" or (state and "ON" or "OFF")))
        debugLog(string.format("Offline row role=%s detail=%s state=%s",
            tostring(getAttr(row, "AXRole")), tostring(detail),
            state == nil and "UNKNOWN" or (state and "ON" or "OFF")))
        return row, state, detail
    end

    print("Actions: visible peek, " .. tostring(getAttr(actionsButton, "AXRole")))
    debugLog("Clicked Actions role=" .. tostring(getAttr(actionsButton, "AXRole")))
    if not clickLikeUser(actionsButton, window) then onError("Could not click visible Actions"); return end
    if batch then batch.menuOpen = true end
    hs.timer.doAfter(MENU_WAIT_SECONDS, function()
        if not shouldContinue() then return end
        local row, alreadyOffline, detail = inspectRow()
        if not row or alreadyOffline == nil then
            print("Offline inspect retry: " .. tostring(detail))
            hs.timer.usleep(450000)
            row, alreadyOffline, detail = inspectRow()
        end
        if not row or alreadyOffline == nil then
            fail(detail or "Could not determine offline state"); return
        end
        if alreadyOffline then
            if batch then batch.pendingOutcome = "already-offline" end
            closeMenu()
            hs.timer.doAfter(0.35, function()
                if shouldContinue() then onComplete("already-offline") end
            end)
            return
        end
        -- OFF has been positively observed. This is the only activation.
        -- Never retry a toggle, including when verification fails or times out.
        if not sameContext() or not clickLikeUser(row, window) then
            fail("Could not enable visible Available offline"); return
        end
        print("Activation: one mouse click after confirmed OFF")
        local verificationAttempts, reopened = 0, false
        local function verify()
            if not shouldContinue() then return end
            if not sameContext() then fail("active window, tab or page changed"); return end
            verificationAttempts = verificationAttempts + 1
            local verifiedRow, enabled, why = inspectRow()
            if verifiedRow and enabled == true then
                if batch then batch.pendingOutcome = "enabled" end
                closeMenu()
                hs.timer.doAfter(0.35, function()
                    if shouldContinue() then onComplete("enabled") end
                end)
                return
            end
            -- Menu dismissal and its Accessibility update can finish at
            -- different times. Reopen Actions at most once; never re-click OFF.
            if not verifiedRow and not reopened then
                local button = findActionsButton(window)
                if button and clickLikeUser(button, window) then
                    reopened = true
                    if batch then batch.menuOpen = true end
                    print("Verification: reopened Actions; offline toggle is not retried")
                    hs.timer.doAfter(MENU_WAIT_SECONDS, verify)
                    return
                end
            end
            if verificationAttempts >= 10 then
                fail("offline enable not confirmed; no retry (" .. tostring(why) .. ")")
                return
            end
            hs.timer.doAfter(0.25, verify)
        end
        hs.timer.doAfter(APPLY_WAIT_SECONDS, verify)
    end)
end


-- ============================================================
-- BATCH CONTROL
-- Option + Command + O toggles start/stop.
-- Start with the first database page already open in peek view.
-- ============================================================

local function batchIsActive(token)
    return batch
        and batch.running
        and generation == token
end


local function batchContextIsCurrent()
    local window = getNotionWindow()
    if not (batch and window and window == batch.window) then return false end
    local web = getActiveWebArea(window)
    if not web then return false end
    -- After Ctrl+Shift+J, Electron may replace the web-area AX node. Treat a
    -- fresh visible web area in the same window as still in-batch.
    if web == batch.web then return true end
    batch.web = web
    return true
end


local function statsMessage(status)
    local total = batch and batch.processed or 0
    local alreadyOffline = batch and batch.alreadyOffline or 0
    local newlyOffline = batch and batch.enabled or 0

    return string.format(
        "%s\n\nTotal pages : %d\nAlready offline pages : %d\nNewly offline ready pages : %d",
        status,
        total,
        alreadyOffline,
        newlyOffline
    )
end


local function showStats(status, seconds)
    if statsAlertId then
        pcall(function()
            hs.alert.closeSpecific(statsAlertId, 0.05)
        end)
    end

    statsAlertId = hs.alert.show(statsMessage(status), seconds or 2)
end


local function finishBatch(reason)
    if not batch or not batch.running then return end

    local finished = batch

    -- If the current page's result is already known, include it even when the
    -- user stops during the short post-action wait.
    if finished.pendingOutcome then
        finished.processed = finished.processed + 1
        if finished.pendingOutcome == "enabled" then
            finished.enabled = finished.enabled + 1
        else
            finished.alreadyOffline = finished.alreadyOffline + 1
        end
        finished.pendingOutcome = nil
    end

    finished.running = false
    generation = generation + 1

    if finished.menuOpen then
        hs.eventtap.keyStroke({}, "escape", 100000)
    end

    debugLog("finishBatch: " .. tostring(reason))
    local summary = statsMessage(reason)
    print("\n" .. summary .. "\n")
    showStats(reason, 6)
    pcall(function()
        local fh = assert(io.open("/tmp/notion-offline-last-stats.txt", "w"))
        fh:write(summary .. "\n")
        fh:close()
    end)
end


local runCurrentBatchPage


local function focusPeekForNavigation(window)
    window = window or getNotionWindow()
    local peek = getPeekRoot(window)
    if not peek then return false end
    local frame = visibleFrame(peek, window) or getAttr(peek, "AXFrame")
    if not frame then return false end
    -- Click inside the peek body (below the header controls) so Notion routes
    -- Ctrl+Shift+J to database navigation instead of the shell/tab chrome.
    local point = {
        x = frame.x + frame.w * 0.50,
        y = frame.y + math.min(220, math.max(90, frame.h * 0.28))
    }
    pcall(function()
        hs.mouse.absolutePosition(point)
        hs.eventtap.leftClick(point, 80000)
    end)
    return true
end


local function getNotionApp()
    local apps = hs.application.applicationsForBundleID("notion.id") or {}
    return apps[1]
end


local function postNotionNextPageShortcut()
    -- Always activate Notion Desktop by bundle id first. Name lookup can
    -- resolve to "Notion Calendar" (com.cron.electron), which beeps and
    -- ignores database peek navigation.
    local app = getNotionApp()
    if not app then return false end
    app:activate(true)
    hs.eventtap.keyStroke({ "ctrl", "shift" }, "J", 20000)
    hs.eventtap.event.newKeyEvent({}, "j", false):post()
    return true
end


local function openNextPage()
    postNotionNextPageShortcut()
end


local function advanceToNextPage(token)
    if not batchIsActive(token) then return end
    if not batchContextIsCurrent() then
        finishBatch("Stopped: active window or tab changed")
        return
    end

    local currentWindow = getNotionWindow()
    -- Pin to the page we just processed; do not re-read a possibly prefetched id.
    local currentSignature = batch.signature or getPageSignature(currentWindow)
    local beforeInfo = batch.pageInfo or describePage(currentWindow)
    if currentSignature and currentSignature:find("^page:") == 1 then
        beforeInfo.peekId = currentSignature
    end

    if not currentSignature then
        finishBatch("Stopped: could not identify current page")
        return
    end

    debugLog("Advancing from signature " .. tostring(currentSignature)
        .. " peekId=" .. tostring(beforeInfo.peekId)
        .. " heading=" .. tostring(beforeInfo.heading))

    local attempts = 0
    local stableCount = 0
    local candidateKey = nil

    local function pollForNextPage()
        if not batchIsActive(token) then return end
        if not batchContextIsCurrent() then
            local notion = (hs.application.applicationsForBundleID("notion.id") or {})[1]
            if notion then
                debugLog("Advance poll: restoring Notion focus")
                notion:activate(true)
            end
            if not batchContextIsCurrent() then
                finishBatch("Stopped: Notion lost focus or active tab changed")
                return
            end
        end

        attempts = attempts + 1
        local nextWindow = getNotionWindow()
        local afterInfo = describePage(nextWindow)
        local changed, why = pageChanged(beforeInfo, afterInfo)
        local nextSignature = getPageSignature(nextWindow)

        debugLog(string.format(
            "Advance poll %d: changed=%s via=%s actions=%s peekId=%s heading=%s fp=%s",
            attempts, tostring(changed), tostring(why), tostring(afterInfo.hasActions),
            tostring(afterInfo.peekId), tostring(afterInfo.heading),
            tostring(afterInfo.fingerprint and afterInfo.fingerprint:sub(1, 80))))

        if changed then
            -- If peekId has not moved yet, identity must come from content signals.
            local settledSignature
            if why == "peekId" then
                settledSignature = afterInfo.peekId
            elseif why == "heading" then
                settledSignature = afterInfo.heading or afterInfo.fingerprint
            else
                settledSignature = afterInfo.fingerprint or afterInfo.heading
                if afterInfo.peekId and beforeInfo.peekId and afterInfo.peekId ~= beforeInfo.peekId then
                    settledSignature = afterInfo.peekId
                end
            end
            settledSignature = settledSignature or nextSignature

            local key = tostring(why) .. ":" .. tostring(settledSignature)
            if key == candidateKey then
                stableCount = stableCount + 1
            else
                candidateKey = key
                stableCount = 1
            end
            if stableCount >= 1 and afterInfo.hasActions then
                batch.signature = settledSignature or batch.signature
                debugLog("Advance settled via " .. tostring(why) .. " -> " .. tostring(batch.signature))
                hs.timer.doAfter(0.7, function()
                    if batchIsActive(token) then runCurrentBatchPage(token) end
                end)
                return
            end
        end

        if attempts >= NEXT_POLL_LIMIT then
            finishBatch(changed
                and "Stopped: next page did not settle"
                or "Finished: no further pages in this view")
            return
        end

        hs.timer.doAfter(NEXT_POLL_SECONDS, pollForNextPage)
    end

    -- Fire the shortcut asynchronously so polling is never blocked on usleep/keyStroke.
    hs.timer.doAfter(0.05, function()
        if not batchIsActive(token) then return end
        debugLog("Sending Ctrl+Shift+J to notion.id")
        openNextPage()
        debugLog("Ctrl+Shift+J sent")
    end)
    hs.timer.doAfter(0.35, pollForNextPage)
end


runCurrentBatchPage = function(token)
    if not batchIsActive(token) then return end
    if not batchContextIsCurrent() then
        finishBatch("Stopped: active window or tab changed")
        return
    end

    if batch.processed >= MAX_PAGES_PER_RUN then
        finishBatch("Stopped at safety limit")
        return
    end

    local window = getNotionWindow()
    local signature = getPageSignature(window)

    if not signature then
        finishBatch("Stopped: could not identify page")
        return
    end

    local pageInfo = describePage(window)
    -- True wrap-around: same peek page id AND same content fingerprint as the
    -- first page. A stale peekId alone must not stop the batch.
    if batch.firstPeekId and pageInfo.peekId and pageInfo.peekId == batch.firstPeekId
        and batch.processed >= 2 then
        if batch.firstFingerprint == nil or pageInfo.fingerprint == batch.firstFingerprint then
            finishBatch("Finished: returned to the first page (sequence complete)")
            return
        end
        debugLog("peekId matches first page but content differs; continuing")
    end

    if batch.visited[signature] then
        debugLog("Duplicate signature " .. tostring(signature) .. "; re-reading")
        hs.timer.usleep(350000)
        window = getNotionWindow() or window
        pageInfo = describePage(window)
        local again = pageInfo.peekId or pageInfo.heading or pageInfo.fingerprint
        if again and again ~= signature then
            signature = again
            debugLog("Signature after re-read: " .. tostring(signature))
        end
        if batch.visited[signature] then
            signature = tostring(signature) .. "#seen" .. tostring(batch.processed + 1)
            debugLog("Using disambiguated signature " .. signature)
        end
    end

    if not batch.firstSignature then
        batch.firstSignature = signature
        batch.firstPeekId = pageInfo.peekId
        batch.firstFingerprint = pageInfo.fingerprint
    end
    batch.visited[signature] = true
    batch.signature = signature
    -- Peek navigation can replace AX nodes. Refresh the batch context every
    -- page so same-tab checks and URL comparisons use the current page.
    batch.window = window
    batch.web = getActiveWebArea(window) or batch.web
    batch.pageURL = urlValue(batch.web)
    batch.pageInfo = pageInfo
    if signature:find("^page:") == 1 then
        batch.pageInfo.peekId = signature
    end

    print(string.format(
        "\nProcessing page %d",
        batch.processed + 1
    ))
    debugLog(string.format(
        "Processing page %d signature=%s actions=%s",
        batch.processed + 1, tostring(signature), tostring(findActionsButton(window) ~= nil)))

    processOnePage(
        function() return batchIsActive(token) end,
        function(outcome)
            if not batchIsActive(token) then return end

            outcome = batch.pendingOutcome or outcome
            batch.pendingOutcome = nil
            batch.processed = batch.processed + 1

            if outcome == "enabled" then
                batch.enabled = batch.enabled + 1
                print("Result: enabled offline")
            else
                batch.alreadyOffline = batch.alreadyOffline + 1
                print("Result: already offline; skipped")
            end

            showStats("Batch running", 2)
            -- Keep batch.signature as the page we just processed. Re-reading
            -- here can pick up the next page too early and then openNextPage
            -- + poll wait forever / lose sync.
            batch.pageURL = urlValue(getActiveWebArea(getNotionWindow()) or batch.web)
            advanceToNextPage(token)
        end,
        function(message)
            if batchIsActive(token) then
                finishBatch("Stopped: " .. message)
            end
        end
    )
end


local function startBatchFromOpenPage()
    local window = getNotionWindow()

    if not window
        or not getPageSignature(window)
        or not findActionsButton(window) then
        hs.alert.show("Open the first database page in peek view")
        return
    end

    generation = generation + 1
    local token = generation

    batch = {
        running = true,
        window = window,
        web = getActiveWebArea(window),
        menuOpen = false,
        pendingOutcome = nil,
        processed = 0,
        enabled = 0,
        alreadyOffline = 0,
        firstSignature = nil,
        firstPeekId = nil,
        firstFingerprint = nil,
        visited = {}
    }

    pcall(function()
        local fh = assert(io.open(DEBUG_LOG_PATH, "w"))
        fh:write("batch start\n")
        fh:close()
    end)
    debugLog("Batch started")
    showStats("Batch started — press Option+Command+O to stop", 4)
    -- The handler runs on key-down. Wait for the user's modifiers to be
    -- released so the first mouse click is not interpreted as a modified click.
    local releasePolls = 0
    local function startAfterRelease()
        if not batchIsActive(token) then return end
        local modifiers = hs.eventtap.checkKeyboardModifiers()
        if modifiers.alt or modifiers.cmd or modifiers.ctrl or modifiers.shift then
            releasePolls = releasePolls + 1
            if releasePolls >= 80 then
                finishBatch("Stopped: release shortcut modifiers and try again")
                return
            end
            hs.timer.doAfter(0.05, startAfterRelease)
            return
        end
        runCurrentBatchPage(token)
    end
    hs.timer.doAfter(0.15, startAfterRelease)
end


local function toggleBatch()
    if batch and batch.running then
        finishBatch("Stopped by user")
    else
        startBatchFromOpenPage()
    end
end


function notionOfflineToggle()
    toggleBatch()
end

function notionOfflineSignature()
    local window = getNotionWindow()
    return tostring(getPageSignature(window))
end


function notionOfflineAdvanceProbe(path)
    path = path or "/tmp/notion-advance-probe.txt"
    local lines = {}
    local window = getNotionWindow()
    local before = getPageSignature(window)
    lines[#lines + 1] = "before=" .. tostring(before)
    local front = hs.application.frontmostApplication()
    lines[#lines + 1] = "front=" .. tostring(front and front:bundleID())
    openNextPage()
    local changed, after = false, before
    for i = 1, 24 do
        hs.timer.usleep(250000)
        window = getNotionWindow()
        after = getPageSignature(window)
        if after and after ~= before then
            changed = true
            lines[#lines + 1] = "changed_at_poll=" .. tostring(i)
            break
        end
    end
    lines[#lines + 1] = "after=" .. tostring(after)
    lines[#lines + 1] = "changed=" .. tostring(changed)
    lines[#lines + 1] = "actions=" .. tostring(findActionsButton(window) ~= nil)
    local fh = assert(io.open(path, "w"))
    fh:write(table.concat(lines, "\n") .. "\n")
    fh:close()
    return table.concat(lines, " | ")
end


local function axSummary(element, depth, lines, budget)
    if not element or budget.count <= 0 or depth > 12 then return end
    budget.count = budget.count - 1
    local role = tostring(getAttr(element, "AXRole"))
    local sub = tostring(getAttr(element, "AXSubrole") or "")
    local desc = tostring(getAttr(element, "AXDescription") or "")
    local title = tostring(getAttr(element, "AXTitle") or "")
    local value = tostring(getAttr(element, "AXValue") or "")
    local ph = tostring(getAttr(element, "AXPlaceholderValue") or "")
    local blob = (desc .. " " .. title .. " " .. value .. " " .. ph):lower()
    local interesting = role == "AXComboBox" or role == "AXList" or role == "AXMenuItem"
        or role == "AXSwitch" or role == "AXCheckBox" or role == "AXPopUpButton"
        or sub == "AXApplicationDialog" or sub == "AXSwitch"
        or blob:find("available offline", 1, true)
        or blob:find("search actions", 1, true)
        or blob:find("actions collection", 1, true)
        or desc == "Actions" or title == "Actions"
    if interesting then
        local f = getAttr(element, "AXFrame")
        lines[#lines + 1] = string.format(
            "d=%d %s sub=%s desc=[%s] title=[%s] value=[%s] ph=[%s] checked=%s enabled=%s hidden=%s frame=%s",
            depth, role, sub, desc, title, value, ph,
            tostring(getAttr(element, "AXChecked")),
            tostring(getAttr(element, "AXEnabled")),
            tostring(getAttr(element, "AXHidden")),
            f and string.format("%.0f,%.0f %.0fx%.0f", f.x, f.y, f.w, f.h) or "nil")
    end
    for _, child in ipairs(getAttr(element, "AXChildren") or {}) do
        axSummary(child, depth + 1, lines, budget)
        if #lines >= 120 then return end
    end
end


function notionOfflineDumpAX(path)
    path = path or "/tmp/notion-ax-live.txt"
    local window = getNotionWindow()
    local lines = {
        "ts=" .. os.date("!%Y-%m-%dT%H:%M:%SZ"),
        "frontmost=" .. tostring(hs.application.frontmostApplication()
            and hs.application.frontmostApplication():bundleID()),
    }
    if not window then
        lines[#lines + 1] = "error=Notion is not frontmost or has no focused window"
    else
        local web = getActiveWebArea(window)
        local peek = getPeekRoot(window)
        local actions = findActionsButton(window)
        lines[#lines + 1] = "web=" .. tostring(web ~= nil)
        lines[#lines + 1] = "peek=" .. tostring(peek ~= nil)
        lines[#lines + 1] = "actions=" .. tostring(actions ~= nil)
        if actions then
            local f = getAttr(actions, "AXFrame")
            lines[#lines + 1] = string.format("actionsFrame=%.0f,%.0f %.0fx%.0f", f.x, f.y, f.w, f.h)
        end
        local budget = { count = 8000 }
        axSummary(window, 0, lines, budget)
        local offline, reason = findOfflineItem(window)
        lines[#lines + 1] = "findOffline=" .. tostring(offline ~= nil)
        lines[#lines + 1] = "findOfflineReason=" .. tostring(reason)
        if offline then
            local ok, state, detail = pcall(isOfflineEnabled, offline, window)
            lines[#lines + 1] = "offlineStateOk=" .. tostring(ok)
            lines[#lines + 1] = "offlineState=" .. tostring(state)
            lines[#lines + 1] = "offlineDetail=" .. tostring(detail)
        end
    end
    local fh = assert(io.open(path, "w"))
    fh:write(table.concat(lines, "\n"))
    fh:write("\n")
    fh:close()
    return path .. " lines=" .. tostring(#lines)
end


function notionOfflineProbeMenu(path)
    path = path or "/tmp/notion-ax-menu.txt"
    local window = getNotionWindow()
    if not window then return "error=no Notion window" end
    local actions = findActionsButton(window)
    if not actions then return "error=no Actions button" end
    if not clickLikeUser(actions, window) then return "error=click Actions failed" end
    hs.timer.usleep(450000)
    return notionOfflineDumpAX(path)
end

function notionOfflineSmokeTest(path)
    path = path or "/tmp/notion-offline-smoke.txt"
    local lines = { "ts=" .. os.date("!%Y-%m-%dT%H:%M:%SZ") }
    local window = getNotionWindow()
    if not window then
        lines[#lines + 1] = "error=no Notion window"
        local fh = assert(io.open(path, "w")); fh:write(table.concat(lines, "\n") .. "\n"); fh:close()
        return "error=no Notion window"
    end
    local actions = findActionsButton(window)
    if not actions then
        lines[#lines + 1] = "error=no Actions button"
        local fh = assert(io.open(path, "w")); fh:write(table.concat(lines, "\n") .. "\n"); fh:close()
        return "error=no Actions button"
    end
    if not clickLikeUser(actions, window) then
        lines[#lines + 1] = "error=click Actions failed"
        local fh = assert(io.open(path, "w")); fh:write(table.concat(lines, "\n") .. "\n"); fh:close()
        return "error=click Actions failed"
    end
    hs.timer.usleep(math.floor(MENU_WAIT_SECONDS * 1000000))
    local row, reason = findOfflineItem(window)
    lines[#lines + 1] = "findOffline=" .. tostring(row ~= nil)
    lines[#lines + 1] = "reason=" .. tostring(reason)
    if not row then
        hs.eventtap.keyStroke({}, "escape", 100000)
        local fh = assert(io.open(path, "w")); fh:write(table.concat(lines, "\n") .. "\n"); fh:close()
        return "error=offline row missing"
    end
    local ok, state, detail = pcall(isOfflineEnabled, row, window)
    lines[#lines + 1] = "stateOk=" .. tostring(ok)
    lines[#lines + 1] = "state=" .. tostring(state)
    lines[#lines + 1] = "detail=" .. tostring(detail)
    if not ok or state == nil then
        hs.eventtap.keyStroke({}, "escape", 100000)
        local fh = assert(io.open(path, "w")); fh:write(table.concat(lines, "\n") .. "\n"); fh:close()
        return "error=unknown state"
    end
    if state == true then
        lines[#lines + 1] = "action=leave-on-unchanged"
        hs.eventtap.keyStroke({}, "escape", 100000)
        local fh = assert(io.open(path, "w")); fh:write(table.concat(lines, "\n") .. "\n"); fh:close()
        return "already-offline"
    end
    lines[#lines + 1] = "action=enable-once"
    if not clickLikeUser(row, window) then
        lines[#lines + 1] = "error=enable click failed"
        local fh = assert(io.open(path, "w")); fh:write(table.concat(lines, "\n") .. "\n"); fh:close()
        return "error=enable click failed"
    end
    hs.timer.usleep(math.floor(APPLY_WAIT_SECONDS * 1000000))
    local row2, reason2 = findOfflineItem(window)
    if not row2 then
        local button = findActionsButton(window)
        if button then clickLikeUser(button, window); hs.timer.usleep(math.floor(MENU_WAIT_SECONDS * 1000000)) end
        row2, reason2 = findOfflineItem(window)
    end
    local ok2, state2, detail2 = pcall(isOfflineEnabled, row2, window)
    lines[#lines + 1] = "verifyFind=" .. tostring(row2 ~= nil)
    lines[#lines + 1] = "verifyReason=" .. tostring(reason2)
    lines[#lines + 1] = "verifyOk=" .. tostring(ok2)
    lines[#lines + 1] = "verifyState=" .. tostring(state2)
    lines[#lines + 1] = "verifyDetail=" .. tostring(detail2)
    hs.eventtap.keyStroke({}, "escape", 100000)
    local fh = assert(io.open(path, "w")); fh:write(table.concat(lines, "\n") .. "\n"); fh:close()
    if ok2 and state2 == true then return "newly-offline" end
    return "error=enable not confirmed"
end


hs.hotkey.deleteAll({ "alt", "cmd" }, "O")

notionOfflineToggleHotkey = hs.hotkey.bind(
    { "alt", "cmd" },
    "O",
    toggleBatch
)
