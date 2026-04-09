-- Credits: 2017 Daniel Ratcliffe
-- Copyright: 2026 ZEGA

--[[
    Improved edit.lua for CC: Tweaked
    - Modular structure with clear separation of concerns
    - Better autocomplete (respects settings, completes tables/fields)
    - Optional line numbers in gutter
    - Improved syntax highlighting patterns
    - Status bar shows file name and modified indicator
    - Search (Ctrl+F) and go to line (Ctrl+G)
    - Undo/redo (limited stack)
    - Performance optimisations for redraw
]]

-- ============================================================================
--  Configuration & Constants
-- ============================================================================

local DEFAULT_EXTENSION = settings.get("edit.default_extension") or "lua"
local AUTOCOMPLETE_ENABLED = settings.get("edit.autocomplete") ~= false
local SHOW_LINE_NUMBERS = settings.get("edit.show_line_numbers") ~= false
local TAB_SIZE = 4

-- ============================================================================
--  Argument Parsing & File Setup
-- ============================================================================

local args = {...}
if #args == 0 then
    local progName = arg[0] or fs.getName(shell.getRunningProgram())
    print("Usage: " .. progName .. " <path>")
    return
end

local filePath = shell.resolve(args[1])
local readOnly = fs.isReadOnly(filePath)
if fs.exists(filePath) and fs.isDir(filePath) then
    printError("Cannot edit a directory.")
    return
end

-- Apply default extension if needed
if not fs.exists(filePath) and not filePath:find("%.") then
    if DEFAULT_EXTENSION ~= "" and type(DEFAULT_EXTENSION) == "string" then
        filePath = filePath .. "." .. DEFAULT_EXTENSION
    end
end

-- ============================================================================
--  Terminal & Colour Setup
-- ============================================================================

local termX, termY = 1, 1
local termWidth, termHeight = term.getSize()
local scrollX, scrollY = 0, 0

local colour = term.isColour()
local colours = colours
local bgColour, textColour = colours.black, colours.white
local highlightColour = colour and colours.yellow or colours.white
local keywordColour = colour and colours.yellow or colours.white
local commentColour = colour and colours.green  or colours.white
local stringColour  = colour and colours.red    or colours.white
local errorColour   = colour and colours.red    or colours.white
local gutterColour  = colour and colours.gray   or colours.white

-- ============================================================================
--  State Variables
-- ============================================================================

local lines = {}              -- file content
local running = true
local menuActive = false
local menuIndex = 1
local menuItems = {}
local statusOk, statusMsg = true, ""

-- Undo/redo stacks
local undoStack, redoStack = {}, {}
local maxUndo = 50
local groupUndo = nil

-- Search state
local searchTerm = nil
local lastSearchIndex = nil

-- Autocomplete state
local completions = nil
local completionIndex = nil

-- Modified flag
local modified = false

-- ============================================================================
--  Utility Functions
-- ============================================================================

local function setStatus(text, ok)
    statusOk = (ok ~= false)
    statusMsg = text
end

local function pushUndo(description)
    if groupUndo then return end
    table.insert(undoStack, {
        lines = {table.unpack(lines)},
        cursor = {termX, termY},
        desc = description
    })
    if #undoStack > maxUndo then table.remove(undoStack, 1) end
    redoStack = {}
    modified = true
end

local function undo()
    if #undoStack == 0 then return end
    local state = table.remove(undoStack)
    table.insert(redoStack, {
        lines = {table.unpack(lines)},
        cursor = {termX, termY},
        desc = state.desc
    })
    lines = state.lines
    termX, termY = state.cursor[1], state.cursor[2]
    modified = true
    redrawText()
    setStatus("Undid " .. (state.desc or "action"))
end

local function redo()
    if #redoStack == 0 then return end
    local state = table.remove(redoStack)
    table.insert(undoStack, {
        lines = {table.unpack(lines)},
        cursor = {termX, termY},
        desc = state.desc
    })
    lines = state.lines
    termX, termY = state.cursor[1], state.cursor[2]
    modified = true
    redrawText()
    setStatus("Redid " .. (state.desc or "action"))
end

-- ============================================================================
--  File I/O
-- ============================================================================

local function loadFile(path)
    lines = {}
    if fs.exists(path) then
        local f = io.open(path, "r")
        if f then
            for line in f:lines() do
                table.insert(lines, line)
            end
            f:close()
        end
    end
    if #lines == 0 then lines = {""} end
    undoStack, redoStack = {}, {}
    modified = false
end

local function saveFile(path, writeFunc)
    local dir = fs.getDir(path)
    if dir ~= "" and not fs.exists(dir) then
        fs.makeDir(dir)
    end
    local ok, err, ferr = pcall(function()
        local f = fs.open(path, "w")
        if not f then error("Failed to open " .. path) end
        writeFunc(f)
        f:close()
    end)
    if ok then
        modified = false
    end
    return ok, err, ferr
end

-- ============================================================================
--  Syntax Highlighting
-- ============================================================================

local keywords = {
    ["and"]=1, ["break"]=1, ["do"]=1, ["else"]=1, ["elseif"]=1,
    ["end"]=1, ["false"]=1, ["for"]=1, ["function"]=1, ["goto"]=1,
    ["if"]=1, ["in"]=1, ["local"]=1, ["nil"]=1, ["not"]=1, ["or"]=1,
    ["repeat"]=1, ["return"]=1, ["then"]=1, ["true"]=1, ["until"]=1, ["while"]=1,
}

local patterns = {
    { "%-%-%[%[.-%]%]", commentColour },
    { "%-%-.*",          commentColour },
    { "\"\"",            stringColour },
    { "\".-[^\\]\"",     stringColour },
    { "''",              stringColour },
    { "'.-[^\\]'",       stringColour },
    { "%[%[.-%]%]",      stringColour },
}

local function writeHighlighted(line)
    local i = 1
    while i <= #line do
        local matched = false
        for _, pat in ipairs(patterns) do
            local m = line:match("^" .. pat[1], i)
            if m then
                term.setTextColour(pat[2])
                term.write(m)
                term.setTextColour(textColour)
                i = i + #m
                matched = true
                break
            end
        end
        if not matched then
            -- Check for keyword / identifier
            local word = line:match("^[%w_]+", i)
            if word then
                if keywords[word] then
                    term.setTextColour(keywordColour)
                else
                    term.setTextColour(textColour)
                end
                term.write(word)
                i = i + #word
            else
                term.setTextColour(textColour)
                term.write(line:sub(i,i))
                i = i + 1
            end
        end
    end
end

-- ============================================================================
--  Autocomplete
-- ============================================================================

local completeEnv = _ENV
local function getCompletions(partial)
    if not AUTOCOMPLETE_ENABLED then return nil end
    local start = partial:find("[%a_][%w_]*$")
    if not start then return nil end
    partial = partial:sub(start)
    if #partial == 0 then return nil end
    return textutils.complete(partial, completeEnv)
end

local function updateCompletions()
    if menuActive or readOnly then
        completions = nil
        completionIndex = nil
        return
    end
    local line = lines[termY]
    if termX == #line + 1 then
        completions = getCompletions(line)
        completionIndex = completions and #completions > 0 and 1 or nil
    else
        completions, completionIndex = nil, nil
    end
end

-- ============================================================================
--  Rendering
-- ============================================================================

local function redrawLine(y)
    local line = lines[y]
    if not line then return end
    term.setCursorPos(1 - scrollX, y - scrollY)
    term.clearLine()
    if SHOW_LINE_NUMBERS then
        term.setTextColour(gutterColour)
        term.write(string.format("%4d ", y))
        term.setTextColour(textColour)
    end
    writeHighlighted(line)
    if y == termY and termX == #line + 1 and completionIndex then
        term.setTextColour(colours.white)
        term.setBackgroundColour(colours.grey)
        term.write(completions[completionIndex])
        term.setTextColour(textColour)
        term.setBackgroundColour(bgColour)
    end
    term.setCursorPos(termX - scrollX, termY - scrollY)
end
local function redrawMenu()
    term.setCursorPos(1, termHeight)
    term.clearLine()
    term.setBackgroundColour(bgColour)

    -- Right side: line number and modified indicator
    local rightText = string.format("Ln %d", termY)
    if modified then rightText = rightText .. " [+]" end
    term.setCursorPos(termWidth - #rightText, termHeight)
    term.setTextColour(highlightColour)
    term.write("Ln ")
    term.setTextColour(textColour)
    term.write(termY)
    if modified then
        term.setTextColour(highlightColour)
        term.write(" [+")
        term.setTextColour(textColour)
        term.write("]")
    end
    term.setCursorPos(1, termHeight)
    if menuActive then
        for i, item in ipairs(menuItems) do
            if i == menuIndex then
                term.setTextColour(highlightColour)
                term.write("[" .. item .. "]")
            else
                term.setTextColour(textColour)
                term.write(" " .. item .. " ")
            end
        end
    else
        term.setTextColour(statusOk and highlightColour or errorColour)
        term.write(statusMsg)
        term.setTextColour(textColour)
    end
    term.setCursorPos(termX - scrollX, termY - scrollY)
end

function redrawText()
    for y = 1, termHeight - 1 do
        local lineIdx = y + scrollY
        if lineIdx <= #lines then
            redrawLine(lineIdx)
        else
            term.setCursorPos(1, y)
            term.clearLine()
        end
    end
    term.setCursorPos(termX - scrollX, termY - scrollY)
    redrawMenu()
end

-- ============================================================================
--  Cursor & Viewport Management
-- ============================================================================

local function setCursor(x, y)
    local oldY = termY
    termX, termY = x, y
    local screenX = termX - scrollX
    local screenY = termY - scrollY
    local needsFullRedraw = false

    if screenX < 1 then
        scrollX = termX - 1
        screenX = 1
        needsFullRedraw = true
    elseif screenX > termWidth then
        scrollX = termX - termWidth
        screenX = termWidth
        needsFullRedraw = true
    end
    if screenY < 1 then
        scrollY = termY - 1
        screenY = 1
        needsFullRedraw = true
    elseif screenY > termHeight - 1 then
        scrollY = termY - (termHeight - 1)
        screenY = termHeight - 1
        needsFullRedraw = true
    end

    updateCompletions()
    if needsFullRedraw then
        redrawText()
    elseif termY ~= oldY then
        redrawLine(oldY)
        redrawLine(termY)
    else
        redrawLine(termY)
    end
    term.setCursorPos(screenX, screenY)
    redrawMenu()
end

-- ============================================================================
--  Editing Operations
-- ============================================================================

local function insertText(text)
    pushUndo("typing")
    local line = lines[termY]
    lines[termY] = line:sub(1, termX-1) .. text .. line:sub(termX)
    setCursor(termX + #text, termY)
end

local function deleteChar()
    local line = lines[termY]
    if termX <= #line then
        pushUndo("delete")
        lines[termY] = line:sub(1, termX-1) .. line:sub(termX+1)
        redrawLine(termY)
    elseif termY < #lines then
        pushUndo("delete line break")
        lines[termY] = line .. lines[termY+1]
        table.remove(lines, termY+1)
        redrawText()
    end
    updateCompletions()
end

local function backspace()
    if termX > 1 then
        pushUndo("backspace")
        local line = lines[termY]
        if termX > TAB_SIZE and line:sub(termX-TAB_SIZE, termX-1) == (" "):rep(TAB_SIZE) and not line:sub(1, termX-1):find("%S") then
            lines[termY] = line:sub(1, termX-TAB_SIZE-1) .. line:sub(termX)
            setCursor(termX - TAB_SIZE, termY)
        else
            lines[termY] = line:sub(1, termX-2) .. line:sub(termX)
            setCursor(termX - 1, termY)
        end
    elseif termY > 1 then
        pushUndo("backspace line")
        local prevLen = #lines[termY-1]
        lines[termY-1] = lines[termY-1] .. lines[termY]
        table.remove(lines, termY)
        setCursor(prevLen + 1, termY - 1)
        redrawText()
    end
end

local function newline()
    pushUndo("new line")
    local line = lines[termY]
    local _, spaces = line:find("^[ ]+")
    local indent = spaces or 0
    lines[termY] = line:sub(1, termX-1)
    table.insert(lines, termY+1, (" "):rep(indent) .. line:sub(termX))
    setCursor(indent + 1, termY + 1)
    redrawText()
end

local function acceptCompletion()
    if completionIndex then
        pushUndo("autocomplete")
        local comp = completions[completionIndex]
        lines[termY] = lines[termY] .. comp
        setCursor(termX + #comp, termY)
    end
end

-- ============================================================================
--  Search Functionality
-- ============================================================================

local function search(forward)
    if not searchTerm or searchTerm == "" then
        term.setCursorPos(1, termHeight)
        term.clearLine()
        term.write("Search: ")
        local input = read()
        if input and input ~= "" then
            searchTerm = input:lower()
            lastSearchIndex = termY
        else
            return
        end
    end
    local start = lastSearchIndex or termY
    local delta = forward and 1 or -1
    for i = 1, #lines do
        local idx = ((start - 1 + i * delta) % #lines) + 1
        local pos = lines[idx]:lower():find(searchTerm, 1, true)
        if pos then
            setCursor(pos, idx)
            lastSearchIndex = idx
            setStatus("Found at line " .. idx)
            return
        end
    end
    setStatus("Not found: " .. searchTerm, false)
end

local function goToLine()
    term.setCursorPos(1, termHeight)
    term.clearLine()
    term.write("Go to line: ")
    local input = read()
    local n = tonumber(input)
    if n and n >= 1 and n <= #lines then
        setCursor(1, n)
        setStatus("Jumped to line " .. n)
    else
        setStatus("Invalid line number", false)
    end
end

-- ============================================================================
--  Menu & Actions
-- ============================================================================

local menuActions = {}

function menuActions.Save()
    if readOnly then
        setStatus("File is read only", false)
        return
    end
    local ok, _, ferr = saveFile(filePath, function(f)
        for _, line in ipairs(lines) do
            f.write(line .. "\n")
        end
    end)
    if ok then
        setStatus("Saved to " .. fs.getName(filePath))
    else
        setStatus("Save failed: " .. (ferr or "unknown error"), false)
    end
    redrawMenu()
end

function menuActions.Print()
    local printer = peripheral.find("printer")
    if not printer then
        setStatus("No printer attached", false)
        return
    end
    if printer.getInkLevel() < 1 then
        setStatus("Printer out of ink", false)
        return
    elseif printer.getPaperLevel() < 1 then
        setStatus("Printer out of paper", false)
        return
    end
    local oldTerm = term.current()
    local page = 0
    local name = fs.getName(filePath)
    local printerTerm = {
        getCursorPos = printer.getCursorPos,
        setCursorPos = printer.setCursorPos,
        getSize = printer.getPageSize,
        write = printer.write,
        scroll = function()
            while not printer.newPage() do
                setStatus("Printer output tray full, please empty")
                term.redirect(oldTerm)
                redrawMenu()
                term.redirect(printerTerm)
                sleep(0.5)
            end
            page = page + 1
            printer.setPageTitle(page == 1 and name or (name .. " (page " .. page .. ")"))
        end,
    }
    menuActive = false
    term.redirect(printerTerm)
    pcall(function()
        printerTerm.scroll()
        for _, line in ipairs(lines) do
            print(line)
        end
    end)
    term.redirect(oldTerm)
    while not printer.endPage() do
        setStatus("Finishing print...")
        redrawMenu()
        sleep(0.5)
    end
    setStatus("Printed " .. page .. " page(s)")
    redrawMenu()
end

function menuActions.Run()
    local title = fs.getName(filePath)
    if title:sub(-4) == ".lua" then title = title:sub(1, -5) end
    local tempPath = readOnly and ".temp." .. title or fs.combine(fs.getDir(filePath), ".temp." .. title)
    local runHandler = [[
        multishell.setTitle(multishell.getCurrent(), %q)
        local current = term.current()
        local contents, name = %q, %q
        local fn, err = load(contents, name, nil, _ENV)
        if fn then
            local ok, err, co = require("cc.internal.exception").try(fn, ...)
            term.redirect(current)
            term.setTextColor(term.isColour() and colours.yellow or colours.white)
            term.setBackgroundColor(colours.black)
            term.setCursorBlink(false)
            if not ok then printError(err) end
        else
            printError(err)
        end
        print("Press any key to continue.")
        os.pullEvent("key")
        require("cc.internal.event").discard_char()
    ]]
    local ok = saveFile(tempPath, function(f)
        f.write(runHandler:format(title, table.concat(lines, "\n"), "@/" .. filePath))
    end)
    if ok then
        local id = shell.openTab("/" .. tempPath)
        if id then
            shell.switchTab(id)
        else
            setStatus("Error starting task", false)
        end
        fs.delete(tempPath)
    else
        setStatus("Error creating temporary file", false)
    end
    redrawMenu()
end

function menuActions.Exit()
    if modified then
        term.setCursorPos(1, termHeight)
        term.clearLine()
        term.write("File modified. Save before exit? (y/n) ")
        local _, key = os.pullEvent("char")
        if key:lower() == "y" then
            menuActions.Save()
        end
    end
    running = false
end

-- ============================================================================
--  Initialisation
-- ============================================================================

loadFile(filePath)
if not readOnly then table.insert(menuItems, "Save") end
if shell.openTab then table.insert(menuItems, "Run") end
if peripheral.find("printer") then table.insert(menuItems, "Print") end
table.insert(menuItems, "Exit")

-- Status message
if readOnly then
    setStatus("Read only", false)
elseif fs.getFreeSpace(filePath) < 1024 then
    setStatus("Low disk space", false)
else
    local msg = term.isColour() and "Press Ctrl or click here for menu" or "Press Ctrl for menu"
    if #msg > termWidth - 5 then msg = "Ctrl for menu" end
    setStatus(msg)
end

term.setBackgroundColour(bgColour)
term.clear()
term.setCursorPos(1, 1)
term.setCursorBlink(true)
updateCompletions()
redrawText()
redrawMenu()

-- ============================================================================
--  Main Event Loop
-- ============================================================================

while running do
    local ev, p1, p2, p3 = os.pullEvent()
    if ev == "key" then
        if p1 == keys.up then
            if not menuActive then
                if completionIndex then
                    completionIndex = completionIndex - 1
                    if completionIndex < 1 then completionIndex = #completions end
                    redrawLine(termY)
                elseif termY > 1 then
                    setCursor(math.min(termX, #lines[termY-1]+1), termY-1)
                end
            end
        elseif p1 == keys.down then
            if not menuActive then
                if completionIndex then
                    completionIndex = completionIndex + 1
                    if completionIndex > #completions then completionIndex = 1 end
                    redrawLine(termY)
                elseif termY < #lines then
                    setCursor(math.min(termX, #lines[termY+1]+1), termY+1)
                end
            end
        elseif p1 == keys.tab then
            if not menuActive and not readOnly then
                if completionIndex and termX == #lines[termY]+1 then
                    acceptCompletion()
                else
                    insertText((" "):rep(TAB_SIZE))
                end
            end
        elseif p1 == keys.pageUp then
            if not menuActive then
                setCursor(termX, math.max(1, termY - (termHeight - 1)))
            end
        elseif p1 == keys.pageDown then
            if not menuActive then
                setCursor(termX, math.min(#lines, termY + (termHeight - 1)))
            end
        elseif p1 == keys.home then
            if not menuActive then setCursor(1, termY) end
        elseif p1 == keys["end"] then
            if not menuActive then setCursor(#lines[termY]+1, termY) end
        elseif p1 == keys.left then
            if not menuActive then
                if termX > 1 then setCursor(termX-1, termY)
                elseif termY > 1 then setCursor(#lines[termY-1]+1, termY-1) end
            else
                menuIndex = menuIndex - 1
                if menuIndex < 1 then menuIndex = #menuItems end
                redrawMenu()
            end
        elseif p1 == keys.right then
            if not menuActive then
                if termX < #lines[termY]+1 then setCursor(termX+1, termY)
                elseif completionIndex and termX == #lines[termY]+1 then acceptCompletion()
                elseif termY < #lines then setCursor(1, termY+1) end
            else
                menuIndex = menuIndex + 1
                if menuIndex > #menuItems then menuIndex = 1 end
                redrawMenu()
            end
        elseif p1 == keys.delete then
            if not menuActive and not readOnly then deleteChar() end
        elseif p1 == keys.backspace then
            if not menuActive and not readOnly then backspace() end
        elseif p1 == keys.enter or p1 == keys.numPadEnter then
            if not menuActive and not readOnly then newline()
            elseif menuActive then menuActions[menuItems[menuIndex]]() end
        elseif p1 == keys.leftCtrl or p1 == keys.rightCtrl then
            menuActive = not menuActive
            term.setCursorBlink(not menuActive)
            redrawMenu()
        elseif p1 == keys.f then
            if p2 == keys.leftCtrl or p2 == keys.rightCtrl then
                search(true)
            end
        elseif p1 == keys.g then
            if p2 == keys.leftCtrl or p2 == keys.rightCtrl then
                goToLine()
            end
        elseif p1 == keys.z then
            if p2 == keys.leftCtrl or p2 == keys.rightCtrl then
                undo()
            end
        elseif p1 == keys.y then
            if p2 == keys.leftCtrl or p2 == keys.rightCtrl then
                redo()
            end
        elseif p1 == keys.s then
            if p2 == keys.leftCtrl or p2 == keys.rightCtrl then
                menuActions.Save()
            end
        end
    elseif ev == "char" then
        if not menuActive and not readOnly then
            insertText(p1)
        elseif menuActive then
            for i, item in ipairs(menuItems) do
                if item:sub(1,1):lower() == p1:lower() then
                    menuActions[item]()
                    break
                end
            end
        end
    elseif ev == "paste" and not readOnly then
        if menuActive then
            menuActive = false
            term.setCursorBlink(true)
            redrawMenu()
        end
        insertText(p1)
    elseif ev == "mouse_click" then
        local cx, cy = p2, p3
        if not menuActive then
            if p1 == 1 then
                if cy < termHeight then
                    local targetLine = scrollY + cy
                    -- Check if the line exists in the table
                    if lines[targetLine] then
                        setCursor(math.min(scrollX + cx, #lines[targetLine] + 1), targetLine)
                    else
                        -- If clicking below the last line, snap to the end of the file
                        setCursor(1, #lines)
                    end
                else
                    menuActive = true
                    redrawMenu()
                end
            end
        else
            if cy == termHeight then
                local pos = 1
                for i, item in ipairs(menuItems) do
                    local nextPos = pos + #item + 1
                    if cx >= pos and cx < nextPos then
                        menuActions[item]()
                        break
                    end
                    pos = nextPos + 1
                end
            else
                menuActive = false
                term.setCursorBlink(true)
                redrawMenu()
            end
        end
    elseif ev == "mouse_scroll" and not menuActive then
        if p1 == -1 then
            scrollY = math.max(0, scrollY - 3)
            redrawText()
        elseif p1 == 1 then
            -- Safety check to ensure we don't scroll into negative math if the file is short
            local maxScroll = math.max(0, #lines - (termHeight - 1))
            scrollY = math.min(maxScroll, scrollY + 3)
            redrawText()
        end
    elseif ev == "term_resize" then
        termWidth, termHeight = term.getSize()
        setCursor(termX, termY)
        redrawText()
    end
end

-- ============================================================================
--  Cleanup
-- ============================================================================

term.clear()
term.setCursorBlink(false)
term.setCursorPos(1, 1)
