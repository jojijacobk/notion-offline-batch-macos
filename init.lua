local ax = hs.axuielement

local MENU_WAIT_SECONDS = 0.7
local APPLY_WAIT_SECONDS = 1.1
local NEXT_POLL_SECONDS = 0.25
local NEXT_POLL_LIMIT = 24
local MAX_PAGES_PER_RUN = 1500

local batch = nil
local generation = 0
local statsAlertId = nil


-- ============================================================
-- ACCESSIBILITY HELPERS
-- ============================================================

local function getAttr(element, name)
    local ok, value = pcall(function()
        return element:attributeValue(name)
    end)
    return ok and value or nil
end


local function findElement(element, matcher)
    if not element then return nil end
    if matcher(element) then return element end

    for _, child in ipairs(getAttr(element, "AXChildren") or {}) do
        local found = findElement(child, matcher)
        if found then return found end
    end

    return nil
end


local function getNotionWindow()
    local app = hs.application.frontmostApplication()
    if not app or app:name() ~= "Notion" then return nil end
    return getAttr(ax.applicationElement(app), "AXFocusedWindow")
end


local function findActionsButton(window)
    return findElement(window, function(element)
        return getAttr(element, "AXRole") == "AXPopUpButton"
            and getAttr(element, "AXDescription") == "Actions"
    end)
end


local function findOfflineItem(window)
    return findElement(window, function(element)
        return getAttr(element, "AXRole") == "AXMenuItem"
            and getAttr(element, "AXValue") == "Available offline"
    end)
end


local function getPeekRoot(window)
    local sidePeek = findElement(window, function(element)
        return getAttr(element, "AXDescription") == "Side Peek"
    end)

    if sidePeek then return sidePeek end

    -- Calendar and gallery views may use a centre peek instead.
    return findElement(window, function(element)
        return getAttr(element, "AXSubrole") == "AXApplicationDialog"
    end)
end


-- Locate with Accessibility, but open with a real mouse click.
local function clickLikeUser(element)
    local frame = getAttr(element, "AXFrame")
    if not frame then return false end

    local point = hs.geometry.point(
        frame.x + frame.w / 2,
        frame.y + frame.h / 2
    )

    hs.mouse.absolutePosition(point)
    hs.eventtap.leftClick(point, 100000)
    return true
end


-- Build a signature from the current Side Peek's accessible text. This lets
-- the loop detect the last page and prevents processing the same page twice.
local function getPageSignature(window)
    if not window then return nil end

    local peek = getPeekRoot(window)
    if not peek then return nil end

    local parts = {}

    local function collect(element)
        local role = getAttr(element, "AXRole")

        if role == "AXHeading"
            or role == "AXStaticText"
            or role == "AXTextArea"
            or role == "AXLink" then

            for _, attribute in ipairs({ "AXTitle", "AXValue" }) do
                local value = getAttr(element, attribute)
                if type(value) == "string" and value ~= "" then
                    parts[#parts + 1] = role .. ":" .. value
                end
            end
        end

        for _, child in ipairs(getAttr(element, "AXChildren") or {}) do
            collect(child)
        end
    end

    collect(peek)

    if #parts == 0 then return nil end
    return table.concat(parts, "\30")
end


-- ============================================================
-- READ THE AVAILABLE-OFFLINE SWITCH
-- ============================================================

local function isOfflineEnabled(offlineItem)
    local frame = getAttr(offlineItem, "AXFrame")
    if not frame then return nil end

    local screen = hs.screen.find(frame)
    if not screen then return nil end

    local image = screen:snapshot(frame)
    if not image then return nil end

    local bitmap = image:bitmapRepresentation({
        w = math.floor(frame.w),
        h = math.floor(frame.h)
    }, false)

    if not bitmap then return nil end

    local size = bitmap:size()
    local sampleXs = {
        size.w * 0.855,
        size.w * 0.87,
        size.w * 0.885
    }
    local y = size.h * 0.50
    local bluePixels = 0

    for _, x in ipairs(sampleXs) do
        local color = bitmap:colorAt(hs.geometry.point(
            math.floor(x),
            math.floor(y)
        ))

        if color
            and color.red
            and color.green
            and color.blue
            and color.blue > 0.65
            and color.blue > color.red + 0.15
            and color.blue > color.green + 0.08 then
            bluePixels = bluePixels + 1
        end
    end

    print("Blue pixels: " .. bluePixels .. "/3")
    return bluePixels >= 2
end


-- ============================================================
-- PROCESS EXACTLY ONE PAGE
-- ============================================================

local function processOnePage(shouldContinue, onComplete, onError)
    if not shouldContinue() then return end

    local window = getNotionWindow()
    if not window then
        onError("Notion is not active")
        return
    end

    local actionsButton = findActionsButton(window)
    if not actionsButton then
        onError("Actions button not found")
        return
    end

    if not clickLikeUser(actionsButton) then
        onError("Could not click Actions")
        return
    end

    if batch and batch.running then batch.menuOpen = true end

    hs.timer.doAfter(MENU_WAIT_SECONDS, function()
        if not shouldContinue() then return end

        local menuWindow = getNotionWindow()
        if not menuWindow then
            onError("Notion window disappeared")
            return
        end

        local offlineItem = findOfflineItem(menuWindow)
        if not offlineItem then
            onError("Available offline not found")
            return
        end

        -- State is inspected before the only press on offlineItem.
        local alreadyOffline = isOfflineEnabled(offlineItem)

        if alreadyOffline == nil then
            onError("Could not determine offline state")
            return
        end

        if alreadyOffline then
            if batch and batch.running then
                batch.pendingOutcome = "already-offline"
            end

            hs.eventtap.keyStroke({}, "escape", 0)
            if batch and batch.running then batch.menuOpen = false end

            hs.timer.doAfter(0.35, function()
                if shouldContinue() then onComplete("already-offline") end
            end)
            return
        end

        local ok, result = pcall(function()
            return offlineItem:performAction("AXPress")
        end)

        if not ok or not result then
            onError("Could not enable Available offline")
            return
        end

        if batch and batch.running then batch.menuOpen = false end
        if batch and batch.running then batch.pendingOutcome = "enabled" end

        hs.timer.doAfter(APPLY_WAIT_SECONDS, function()
            if shouldContinue() then onComplete("enabled") end
        end)
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
        hs.eventtap.keyStroke({}, "escape", 0)
    end

    local summary = statsMessage(reason)
    print("\n" .. summary .. "\n")
    showStats(reason, 6)
end


local runCurrentBatchPage


local function advanceToNextPage(token)
    if not batchIsActive(token) then return end

    local currentWindow = getNotionWindow()
    local currentSignature = getPageSignature(currentWindow)

    if not currentSignature then
        finishBatch("Stopped: could not identify current page")
        return
    end

    hs.eventtap.keyStroke({ "ctrl", "shift" }, "J", 0)

    local attempts = 0
    local candidate = nil
    local stableCount = 0

    local function pollForNextPage()
        if not batchIsActive(token) then return end

        attempts = attempts + 1

        local nextWindow = getNotionWindow()
        local nextSignature = getPageSignature(nextWindow)

        if nextSignature and nextSignature ~= currentSignature then
            if nextSignature == candidate then
                stableCount = stableCount + 1
            else
                candidate = nextSignature
                stableCount = 1
            end

            if stableCount >= 2 and findActionsButton(nextWindow) then
                hs.timer.doAfter(0.35, function()
                    if batchIsActive(token) then runCurrentBatchPage(token) end
                end)
                return
            end
        else
            candidate = nil
            stableCount = 0
        end

        if attempts >= NEXT_POLL_LIMIT then
            finishBatch("Finished: reached the last page")
            return
        end

        hs.timer.doAfter(NEXT_POLL_SECONDS, pollForNextPage)
    end

    hs.timer.doAfter(NEXT_POLL_SECONDS, pollForNextPage)
end


runCurrentBatchPage = function(token)
    if not batchIsActive(token) then return end

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

    if batch.visited[signature] then
        finishBatch("Finished: page sequence repeated")
        return
    end

    batch.visited[signature] = true

    print(string.format(
        "\nProcessing page %d",
        batch.processed + 1
    ))

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
        menuOpen = false,
        pendingOutcome = nil,
        processed = 0,
        enabled = 0,
        alreadyOffline = 0,
        visited = {}
    }

    showStats("Batch started — press Option+Command+O to stop", 4)
    runCurrentBatchPage(token)
end


local function toggleBatch()
    if batch and batch.running then
        finishBatch("Stopped by user")
    else
        startBatchFromOpenPage()
    end
end


hs.hotkey.deleteAll({ "alt", "cmd" }, "O")

notionOfflineToggleHotkey = hs.hotkey.bind(
    { "alt", "cmd" },
    "O",
    toggleBatch
)
