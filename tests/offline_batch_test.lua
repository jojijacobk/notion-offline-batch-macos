-- Run with: lua tests/offline_batch_test.lua
-- Simulated Accessibility + timer events exercise safety-critical batch behavior.
local f = assert(io.open('init.lua')); local source = f:read('*a'); f:close()
local exports = [[
return { actions=findActionsButton, row=findOfflineItem, state=isOfflineEnabled,
 active=getActiveWebArea, signature=getPageSignature, toggle=toggleBatch,
 batch=function() return batch end, attr=getAttr }
]]
local function eq(actual, expected, label)
    assert(actual == expected, (label or 'value')..': expected '..tostring(expected)..', got '..tostring(actual))
end
local function fixture(states, options)
    options = options or {}
    local s = { now=0, queue={}, page=1, states=states or {true}, menu=false,
        clicks=0, advances=0, escapes=0, bindings=0, logs={}, active=true }
    local function node(role, frame, attrs, children)
        local e=attrs or {}; e.AXRole=role; e.AXFrame=frame; e.AXChildren=children or {}
        if e.AXEnabled == nil then e.AXEnabled=true end
        function e:attributeValue(k) return self[k] end
        for _,c in ipairs(e.AXChildren) do c.AXParent=e end
        return e
    end
    local function rect(x,y,w,h) return {x=x,y=y,w=w,h=h} end
    local win=node('AXWindow',rect(0,0,1102,745))
    local web=node('AXWebArea',rect(0,59,1102,686),{AXTitle='Current'})
    local old=node('AXWebArea',rect(1101,744,1102,686),{AXTitle='Inactive',AXFocused=true})
    local oldAction=node('AXPopUpButton',rect(2169,751,25,26),{AXDescription='Actions'})
    old.AXChildren={oldAction};oldAction.AXParent=old
    win.AXChildren={old,web};old.AXParent=win;web.AXParent=win
    local background=node('AXPopUpButton',rect(1068,66,25,26),{AXDescription='Actions'})
    local action=node('AXPopUpButton',rect(1068,66,25,26),{AXDescription='Actions'})
    local link=node('AXLink',rect(591,66,20,26),{AXDescription='Open in full page'})
    local peek=node('AXGroup',rect(551,59,551,686),{AXDescription='Side Peek'}, {link,action})
    local body=node('AXGroup',web.AXFrame,{}, {background,peek});body.AXParent=web
    local row=node(options.rowRole or 'AXGroup',rect(864,378,224,26),{AXValue='Available offline',AXSelected=true})
    local search=node('AXComboBox',rect(897,113,179,18),{AXPlaceholderValue='Search actions…'})
    local list=node('AXList',rect(861,142,231,506),{}, {row})
    local panel=node('AXGroup',rect(861,99,231,549),{AXSubrole='AXApplicationDialog'}, {search,list});panel.AXParent=web
    local function update()
        local id=(options.ids or {})[s.page] or string.format('%032x',s.page)
        web.AXURL={url='https://app.notion.com/p/database?p='..id..'&pm=s'}
        link.AXURL={url='https://app.notion.com/p/AIDLC-'..id..'?pvs=23'}
        web.AXChildren=s.menu and {panel} or {body}
    end
    update()
    local app={
        bundleID=function() return s.active and 'notion.id' or 'other.app' end,
        name=function() return 'Notion' end,
        activate=function() end,
        pid=function() return 1 end,
    }
    local appAX={attributeValue=function(_,k)
        if k=='AXFocusedWindow' then return win end
        if k=='AXFocusedUIElement' then return s.menu and search or web end
    end}
    local function inside(p,r) return r and r.w>0 and r.h>0 and p.x>=r.x and p.x<=r.x+r.w and p.y>=r.y and p.y<=r.y+r.h end
    local function hit(e,p)
        if e.AXHidden or not inside(p,e.AXFrame) then return nil end
        for i=#e.AXChildren,1,-1 do local h=hit(e.AXChildren[i],p); if h then return h end end
        return e
    end
    local bitmap={}
    function bitmap:colorAt(p)
        if options.blank then return {red=1,green=1,blue=1} end
        if options.missingPixels then return nil end
        local left=p.x<203
        local isOn=s.states[s.page]
        if (isOn and not left) or (not isOn and left) then return {red=1,green=1,blue=1} end
        if isOn then return {red=.13,green=.42,blue=.84} end
        return {red=.84,green=.84,blue=.84}
    end
    local image={bitmapRepresentation=function() return bitmap end}
    local screen={fullFrame=function() return rect(0,0,1147,745) end,
        absoluteToLocal=function(_,r) return r end,
        snapshot=function() s.captures=(s.captures or 0)+1; if options.noCapture then return nil end; return image end}
    local hs={keycodes={map={ctrl='ctrl',shift='shift',j='j'}},application={frontmostApplication=function() return app end,applicationsForBundleID=function(bid) if bid=='notion.id' and s.active then return {app} end return {} end,get=function(name) return app end},

        axuielement={applicationElement=function() return appAX end,
            systemWideElement=function() return {elementAtPosition=function(_,p)
                if options.covered then return node('AXWindow',win.AXFrame) end
                if options.documentHit then return web end
                return hit(win,p)
            end} end},
        screen={find=function() return screen end},geometry={point=function(x,y) return {x=x,y=y} end},
        mouse={absolutePosition=function() end},
        timer={usleep=function() end,secondsSinceEpoch=function() return s.now end,doAfter=function(delay,fn) s.queue[#s.queue+1]={at=s.now+delay,fn=fn} end},
        eventtap={checkKeyboardModifiers=function() return {} end},alert={show=function(message) s.lastAlert=message; return 'alert' end,closeSpecific=function() end},
        hotkey={deleteAll=function(mods,key) eq(table.concat(mods,','),'alt,cmd');eq(key,'O') end,
            bind=function(mods,key,fn) s.bindings=s.bindings+1; s.hotkey=fn; eq(key,'O');return {} end}}
    function hs.eventtap.leftClick(p)
        local target=hit(win,p)
        if target==action then s.menu=true
        elseif target==row then
            s.clicks=s.clicks+1
            assert(not s.states[s.page], 'attempted to toggle ON page OFF')
            if not options.ignoreClick then s.states[s.page]=true end
            if not options.keepMenu then s.menu=false end
        else
            -- Focus clicks inside the peek body are intentional before Ctrl+Shift+J.
            s.focusClicks=(s.focusClicks or 0)+1
        end
        update()
    end
    function hs.eventtap.keyStroke(mods,key)
        if key=='escape' then s.escapes=s.escapes+1;s.menu=false
        elseif key=='J' or key=='j' then
            eq(table.concat(mods,','),'ctrl,shift');s.advances=s.advances+1
            if s.page<#s.states then s.page=s.page+1 end
        else error('unexpected keystroke '..key) end
        update()
    end
    local held={ctrl=false,shift=false}
    hs.eventtap.event={newKeyEvent=function(modsOrKey, keyOrDown, maybeDown)
        -- Support both (keycode, down) and (mods, key, down) forms.
        local mods, key, down
        if maybeDown ~= nil then
            mods, key, down = modsOrKey, keyOrDown, maybeDown
        else
            mods, key, down = {}, modsOrKey, keyOrDown
        end
        if type(mods) == 'table' then
            for _, m in ipairs(mods) do held[m]=true end
        end
        return {post=function()
            if key=='ctrl' or key==hs.keycodes.map.ctrl then held.ctrl=down
            elseif key=='shift' or key==hs.keycodes.map.shift then held.shift=down
            elseif (key=='j' or key=='J') and down then
                assert(held.ctrl and held.shift, 'next-page shortcut missing modifiers')
                hs.eventtap.keyStroke({'ctrl','shift'},'J')
            elseif (key=='j' or key=='J') and not down then
                held.ctrl=false; held.shift=false
            end
        end}
    end}
    local env=setmetatable({hs=hs,print=function(...) s.logs[#s.logs+1]=table.concat({...},' ') end},{__index=_G})
    local code=source
    if options.limit then code=code:gsub('MAX_PAGES_PER_RUN = 1500','MAX_PAGES_PER_RUN = '..options.limit) end
    s.api=assert(load(code..exports,'init-test','t',env))()
    function s.run(untilTime)
        local count=0
        while #s.queue>0 do
            table.sort(s.queue,function(a,b)return a.at<b.at end)
            local item=s.queue[1]
            if untilTime and item.at>untilTime then s.now=untilTime;return end
            table.remove(s.queue,1);s.now=item.at;item.fn();count=count+1
            assert(count<200,'timer loop did not terminate')
        end
    end
    s.window,s.web,s.old,s.action,s.row,s.peek=win,web,old,action,row,peek
    s.open=function() s.menu=true;update() end
    return s
end
local tests={
    {'visible tab and peek, not background or inactive Actions',function()
        local s=fixture();eq(s.api.actions(s.window),s.action);eq(s.api.active(s.window),s.web)
        eq(s.api.signature(s.window),'page:'..string.format('%032x',1));eq(s.bindings,1)
        s.action.AXHidden=true;eq(s.api.actions(s.window),nil)
        s.action.AXHidden=false;s.action.AXFrame.w=0;eq(s.api.actions(s.window),nil)
        s.action.AXFrame.w=25;s.action.AXFrame.x=2200;eq(s.api.actions(s.window),nil)
    end},
    {'false Accessibility attributes remain false',function()
        local s=fixture();s.action.AXEnabled=false;eq(s.api.attr(s.action,'AXEnabled'),false);eq(s.api.actions(s.window),nil)
    end},
    {'generic row and ON visual state do not activate',function()
        local s=fixture();s.open();eq(s.api.row(s.window),s.row);eq(s.api.state(s.row,s.window),true);eq(s.clicks,0)
    end},
    {'Accessibility state overrides pixels and ignores AXSelected',function()
        local s=fixture({true},{blank=true});s.open();s.row.AXChecked=false
        eq(s.api.state(s.row,s.window),false);eq(s.captures,nil);s.row.AXChecked=nil
        eq(s.api.state(s.row,s.window),nil)
    end},
    {'blank or missing pixels are UNKNOWN, never OFF',function()
        for _,o in ipairs({{blank=true},{missingPixels=true},{noCapture=true}}) do
            local s=fixture({false},o);s.hotkey();s.run();eq(s.clicks,0);eq(s.api.batch().processed,0)
        end
    end},
    {'ON then OFF batch: count correctly, one activation, advance, stop at end',function()
        local s=fixture({true,false});s.hotkey();s.run();local b=s.api.batch()
        eq(s.clicks,1);eq(b.processed,2);eq(b.alreadyOffline,1);eq(b.enabled,1);eq(s.advances,2);eq(b.running,false)
    end},
    {'menu staying open after enable is verified without another click',function()
        local s=fixture({false},{keepMenu=true});s.hotkey();s.run();eq(s.clicks,1);eq(s.api.batch().enabled,1)
    end},
    {'failed enable is not retried or counted',function()
        local s=fixture({false},{ignoreClick=true});s.hotkey();s.run();eq(s.clicks,1);eq(s.api.batch().processed,0);eq(s.advances,0)
    end},
    {'manual stop before state read cancels all pending callbacks',function()
        local s=fixture({false});s.hotkey();s.run(.2);s.hotkey();s.run();eq(s.clicks,0);eq(s.api.batch().processed,0)
    end},
    {'manual stop after click leaves ON and does not claim unverified success',function()
        local s=fixture({false});s.hotkey();s.run(1.45);s.hotkey();s.run();eq(s.clicks,1);eq(s.states[1],true);eq(s.api.batch().enabled,0)
    end},
    {'restart invalidates prior run callbacks',function()
        local s=fixture({false});s.hotkey();s.run(.2);s.hotkey();s.hotkey();s.run();eq(s.clicks,1);eq(s.api.batch().enabled,1)
    end},
    {'focus loss stops without Escape or click in another application',function()
        local s=fixture({false});s.hotkey();s.active=false;s.run();eq(s.clicks,0);eq(s.escapes,0);eq(s.api.batch().running,false)
    end},
    {'repeated page and safety limit stop the loop',function()
        local a=string.rep('a',32);local b=string.rep('b',32)
        local s=fixture({true,true,true},{ids={a,b,a}});s.hotkey();s.run();eq(s.api.batch().processed,2)
        s=fixture({true,true},{limit=1});s.hotkey();s.run();eq(s.api.batch().processed,1);eq(s.api.batch().running,false)
    end},
    {'Notion document-level hit tests still require the correct focused panel',function()
        local s=fixture({true,false},{documentHit=true});s.hotkey();s.run();eq(s.clicks,1);eq(s.api.batch().processed,2)
    end},
    {'stop during confirmed ON settle includes that page once',function()
        local s=fixture({true});s.hotkey();s.run(1.45);s.hotkey();s.run();eq(s.api.batch().processed,1);eq(s.api.batch().alreadyOffline,1);eq(s.advances,0)
    end},
    {'conflicting Accessibility state stops without activation',function()
        local s=fixture({false});s.row.AXChecked=true
        local child={AXRole='AXCheckBox',AXValue=0,AXChildren={},AXParent=s.row};function child:attributeValue(k)return self[k]end
        s.row.AXChildren={child};s.hotkey();s.run();eq(s.clicks,0);eq(s.api.batch().processed,0)
    end},
    {'covered controls cannot be clicked',function()
        local s=fixture({false},{covered=true});eq(s.api.actions(s.window),nil);eq(s.clicks,0)
    end},
}
for _,t in ipairs(tests) do t[2]();print('PASS '..t[1]) end
print(string.format('%d safety regression tests passed',#tests))
