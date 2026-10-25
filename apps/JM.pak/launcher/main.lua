
local GameManager = require('GameManager')
local Carousel = require('Carousel')
local Covers = require('Covers')
local Font = require('font')
local Icon = require('icon')
local utf8 = require('utf8')

--------------------------------------------------
-- CONFIGURATION
--------------------------------------------------

local groups = GameManager.groups
local groupIndex = 1
local carousel = Carousel.new()

-- Remember the selected game independently for each resolution tab.
local tabSelections = {}

local function rememberTabSelection()
    tabSelections[groupIndex] = carousel.index
end

local function restoreTabSelection()
    local g = groups[groupIndex]
    local count = g and #g.games or 0
    local index = math.max(1, math.min(count, tabSelections[groupIndex] or 1))
    carousel:reset()
    carousel.index = index
    carousel.position = index
    carousel.target = index
    carousel.velocity = 0
end

local W, H = 640, 480
local FOOTER_Y, FOOTER_H = 438, 42

local LOGO_PATH = 'Assets/jm_logo_pixel.png'
local BACKGROUND_PATH = 'Assets/background_pixel.png'
local FONT_PATH = 'Assets/Font/Font.ttf'

local RESUME_FILE = '/tmp/jm_resume'
local STATE_FILE = '/tmp/jm_launcher_state'

-- Theme and layout preferences (stored in Love2D save directory).
local themes = {'Default','Ruby','Sapphire','Pinky','RetroGray','Zelda','Pokemon'}
local palettes = {
    Default={70,175,245}, Ruby={230,65,85}, Sapphire={75,120,245},
    Pinky={245,115,190}, RetroGray={160,165,170},
    Zelda={85,195,105}, Pokemon={245,195,55}
}
local themeIndex, layoutIndex = 1, 1
local themeMenu, menuRow = false, 1
local function saveTheme()
    love.filesystem.write('jm_theme.cfg', tostring(themeIndex)..'\n'..tostring(layoutIndex))
end
local function loadTheme()
    local raw = love.filesystem.read('jm_theme.cfg')
    if raw then
        local a,b = raw:match('(%d+)%s+(%d+)')
        themeIndex = math.max(1,math.min(#themes,tonumber(a) or 1))
        layoutIndex = math.max(1,math.min(2,tonumber(b) or 1))
    end
end

local font = {}
local background = nil
local function applyThemeAssets()
    local name = themes[themeIndex]
    local bgPath = themeIndex == 1 and BACKGROUND_PATH or ('Assets/Themes/'..name..'/background.png')
    if love.filesystem.getInfo(bgPath) then
        background = love.graphics.newImage(bgPath)
    else
        background = love.graphics.newImage(BACKGROUND_PATH)
    end
    if Icon.setTheme then Icon.setTheme(name) end
end
local logoJM = nil

local message = ''
local messageTime = 0

local TAB_DURATION = 0.28
local TAB_SLIDE = 95

local tabTransition = {
    active = false,
    time = 0,
    direction = 1,
    oldCanvas = nil,
    newCanvas = nil
}

local tabIndicatorX = nil

-- Gentle idle floating motion for carousel cards.
local FLOAT_SPEED = 1.65
local FLOAT_AMPLITUDE = 4.0
local floatTime = 0

-- Grid D-pad focus animation (no Canvas or stencil required).
local GRID_FOCUS_DURATION = 0.19
local gridFocus = { from = 1, to = 1, time = GRID_FOCUS_DURATION }

-- Each grid title slides down and disappears when focused, then slides
-- back up when focus leaves. Keep independent progress per game.
local GRID_TITLE_SPEED = 12
local gridTitleProgress = {}


--------------------------------------------------
-- GAME LAUNCH ANIMATION
--------------------------------------------------

local LAUNCH_DURATION = 0.7
local launchAnimation = {
    active = false,
    time = 0,
    fps = 30,
    selectedGame = nil,
    launched = false
}

--------------------------------------------------
-- LAUNCHER ENTRANCE ANIMATION
--------------------------------------------------

local INTRO_DURATION = 0.95
local introAnimation = {
    active = true,
    time = 0
}

-- Reverse fly-out when leaving the launcher with B / Escape.
local EXIT_DURATION = 0.75
local exitAnimation = {
    active = false,
    time = 0,
    requested = false
}

-- Stable, deterministic entry paths (no random flicker).
local function introTransform(offset, t)
    local slot = math.floor(offset + 0.5)
    local stagger = 0.055 * math.min(math.abs(slot), 3)
    local progress = math.max(0, math.min(1,
        (t - stagger) / (1 - stagger)
    ))
    local eased = 1 - (1 - progress) ^ 3
    local remaining = 1 - eased
    local directions = {
        {-510, -330, -0.55},
        { 480, -320,  0.46},
        {-530,  280,  0.38},
        { 500,  320, -0.43},
        {   0, -520,  0.62},
        {-460,  120, -0.36},
        { 450, -120,  0.40}
    }
    local entry = directions[((slot + 3) % #directions) + 1]
    return entry[1] * remaining,
           entry[2] * remaining,
           entry[3] * remaining,
           0.72 + 0.28 * eased,
           eased
end

--------------------------------------------------
-- HELPERS
--------------------------------------------------

local function color(r, g, b, a)
    if themeIndex ~= 1 then
        local p = palettes[themes[themeIndex]]
        -- Recolor blue/cyan interface accents, leaving covers untouched.
        if b > r * 1.12 and b > g * 1.03 then
            local intensity = math.max(r,g,b)/255
            r,g,b = p[1]*intensity,p[2]*intensity,p[3]*intensity
        end
    end
    love.graphics.setColor(r / 255, g / 255, b / 255, a or 1)
end

local function rect(x, y, w, h, r)
    love.graphics.rectangle(
        'fill',
        x, y, w, h,
        r or 0,
        r or 0
    )
end

local function label(s, x, y, w, align, size)
    love.graphics.setFont(font[size or 'normal'])

    love.graphics.printf(
        tostring(s or ''),
        x, y, w,
        align or 'center'
    )
end

-- Keep a title on one line and inside its allotted width.
-- Show only characters that fit on one line, without an ellipsis.
local function truncateText(value, maxWidth, textFont)
    local text = tostring(value or ''):gsub('[\r\n]+', ' ')
    maxWidth = math.max(0, maxWidth)
    if textFont:getWidth(text) <= maxWidth then return text end

    local result = ''
    local ok = pcall(function()
        for _, code in utf8.codes(text) do
            local ch = utf8.char(code)
            if textFont:getWidth(result .. ch) > maxWidth then break end
            result = result .. ch
        end
    end)
    if not ok then return '' end
    return result
end

local function smoothstep(t)
    t = math.max(0, math.min(1, t))
    return t * t * (3 - 2 * t)
end

local function group()
    return groups[groupIndex]
end

local function game()
    local g = group()

    if not g then
        return nil
    end

    return g.games[carousel.index]
end

--------------------------------------------------
-- JAR FILE SIZE (CACHED)
--------------------------------------------------

local jarSizeCache = {}

local function formatJarSize(path)
    if not path or path == '' then
        return '-'
    end

    if jarSizeCache[path] then
        return jarSizeCache[path]
    end

    local f = io.open(path, 'rb')
    if not f then
        jarSizeCache[path] = '-'
        return '-'
    end

    local bytes = f:seek('end')
    f:close()

    if not bytes then
        jarSizeCache[path] = '-'
        return '-'
    end

    local result
    if bytes >= 1024 * 1024 then
        result = string.format('%.2f MB', bytes / (1024 * 1024))
    else
        result = string.format('%.2f KB', bytes / 1024)
    end

    jarSizeCache[path] = result
    return result
end

local function notify(s)
    message = tostring(s or '')
    messageTime = 2.5
end

--------------------------------------------------
-- SAVE / RESTORE LAUNCHER STATE
--------------------------------------------------

local function saveLauncherState()
    local selected = game()

    if not selected or not selected.path then
        return false
    end

    local f = io.open(STATE_FILE, 'w')

    if not f then
        return false
    end

    f:write(selected.path, '\n')
    f:close()

    return true
end

local function restoreLauncherState()
    local f = io.open(STATE_FILE, 'r')

    if not f then
        return false
    end

    local savedPath = f:read('*l')
    f:close()

    if not savedPath or savedPath == '' then
        return false
    end

    for i, g in ipairs(groups) do
        for j, item in ipairs(g.games) do
            if item.path == savedPath then
                groupIndex = i

                carousel:reset()
                carousel.index = j

                -- Synchronize the visual position.
                -- This avoids animating from game 1.
                if carousel.position ~= nil then
                    carousel.position = j
                end

                if carousel.target ~= nil then
                    carousel.target = j
                end

                if carousel.velocity ~= nil then
                    carousel.velocity = 0
                end

                rememberTabSelection()
                return true
            end
        end
    end

    return false
end

local function initializeSelection()
    groupIndex = 1
    carousel:reset()

    local f = io.open(RESUME_FILE, 'r')

    if f then
        f:close()

        -- Consume the resume flag once.
        os.remove(RESUME_FILE)

        restoreLauncherState()
    end
end

--------------------------------------------------
-- ICON HELPERS
--------------------------------------------------

local function iconWidth(img, h)
    if not img then
        return 0
    end

    local iw, ih = img:getDimensions()
    return iw * h / ih
end

local function drawIcon(img, x, y, h)
    if not img then
        return
    end

    local _, ih = img:getDimensions()

    color(255, 255, 255)

    love.graphics.draw(
        img,
        x, y,
        0,
        h / ih,
        h / ih
    )
end

local function footerIcon(img, text, x, y, w, h)
    local gap = img and 5 or 0

    local total =
        iconWidth(img, h) +
        gap +
        font.tiny:getWidth(text)

    local sx = x + (w - total) / 2

    drawIcon(img, sx, y, h)

    love.graphics.setColor(0.96,0.97,0.99,1)
    love.graphics.setFont(font.tiny)

    love.graphics.print(
        text,
        sx + iconWidth(img, h) + gap,
        y + (h - font.tiny:getHeight()) / 2
    )
end

local function footerText(key, description, x, y, w)
    local gap = 7

    local total =
        font.tiny:getWidth(key) +
        gap +
        font.tiny:getWidth(description)

    local sx = x + (w - total) / 2

    love.graphics.setFont(font.tiny)

    love.graphics.setColor(1,0.83,0.43,1)
    love.graphics.print(key, sx, y)

    love.graphics.setColor(0.96,0.97,0.99,1)

    love.graphics.print(
        description,
        sx + font.tiny:getWidth(key) + gap,
        y
    )
end

local function footerResolution(x, y, w)
    local h = 14
    local gap = 4

    local a = iconWidth(Icon.L1, h)
    local b = iconWidth(Icon.R1, h)
    local text = 'Resolution'

    local total =
        a + b +
        2 * gap +
        font.tiny:getWidth(text)

    local sx = x + (w - total) / 2

    drawIcon(Icon.L1, sx, y + 2, h)
    drawIcon(Icon.R1, sx + a + gap, y + 2, h)

    love.graphics.setColor(0.96,0.97,0.99,1)
    love.graphics.setFont(font.tiny)

    love.graphics.print(
        text,
        sx + a + b + 2 * gap,
        y + 2 + (h - font.tiny:getHeight()) / 2
    )
end

--------------------------------------------------
-- BACKGROUND
--------------------------------------------------

local function drawBackground()
    if background then
        color(255,255,255)
        local iw, ih = background:getDimensions()
        -- Cover the 4:3 viewport without distortion.
        local scale = math.max(W / iw, H / ih)
        love.graphics.draw(background, (W-iw*scale)/2, (H-ih*scale)/2, 0, scale, scale)
    else
        color(7,20,35)
        rect(0,0,W,H)
    end

    -- Quiet, dark surfaces behind text. No heavy text outlines.
    love.graphics.setColor(0.025,0.045,0.075,0.84)
    rect(0,0,W,96)
    if layoutIndex == 1 then
        love.graphics.setColor(0.025, 0.045, 0.075, 0.80)
        rect(0, FOOTER_Y - 90, W, 90)
    elseif layoutIndex == 2 then
        love.graphics.setColor(0.025, 0.045, 0.075, 0.80)
        rect(0, FOOTER_Y - 55, W, 55)
    end
end

--------------------------------------------------
-- HEADER
--------------------------------------------------

local function drawHeader()
    -- JM Pixel Art logo
    if logoJM then
        local iw, ih = logoJM:getDimensions()

        local maxW = 80
        local maxH = 42

        local scale = math.min(
            maxW / iw,
            maxH / ih
        )

        color(255, 255, 255)

        love.graphics.draw(
            logoJM,
            15,
            4 + (42 - ih * scale) / 2,
            0,
            scale,
            scale
        )
    end

    -- Original title
    love.graphics.setColor(0.96,0.97,0.99,1)

    label(
        'JAVA MOBILE GAMES',
        105, 14, 360,
        'left', 'normal'
    )

    -- Clock
    color(220, 243, 255)

    label(
        os.date('%H:%M'),
        545, 14, 82,
        'right', 'normal'
    )

    -- Resolution tabs
    local count = #groups

    if count == 0 then
        return
    end

    local tabW = 115
    local start = (W - tabW * count) / 2

    for i, g in ipairs(groups) do
        local x = start + (i - 1) * tabW

        if i == groupIndex then
            color(12, 103, 167, 0.92)
        else
            color(5, 33, 70, 0.85)
        end

        rect(x, 50, tabW - 5, 33, 6)

        color(
            i == groupIndex and 107 or 38,
            i == groupIndex and 233 or 111,
            i == groupIndex and 255 or 162
        )

        love.graphics.setLineWidth(1)

        love.graphics.rectangle(
            'line',
            x, 50,
            tabW - 5, 33,
            6, 6
        )

        color(240, 250, 255)

        label(
            g.label,
            x, 57,
            tabW - 5,
            'center', 'small'
        )
    end

    -- Animated tab indicator
    local targetX =
        start + (groupIndex - 1) * tabW

    local indicatorX = tabIndicatorX or targetX

    color(89, 226, 255, 0.25)

    rect(
        indicatorX - 2,
        82,
        tabW - 1,
        5,
        2
    )

    color(107, 244, 255)

    rect(
        indicatorX + 4,
        83,
        tabW - 13,
        2,
        1
    )
end

--------------------------------------------------
-- GAME COVER
--------------------------------------------------

local function drawCover(g, x, y, w, h, selected, opacity, suppressTitle)
    local img = Covers.get(g)

    color(4, 25, 53, opacity)

    rect(
        x - 4,
        y - 4,
        w + 8,
        h + 8,
        6
    )

    color(
        selected and 101 or 48,
        selected and 235 or 143,
        255,
        opacity
    )

    love.graphics.setLineWidth(
        selected and 3 or 1
    )

    love.graphics.rectangle(
        'line',
        x - 2,
        y - 2,
        w + 4,
        h + 4,
        5, 5
    )

    love.graphics.setLineWidth(1)

    if img then
        local iw, ih = img:getDimensions()

        local scale = math.min(
            w / iw,
            h / ih
        )

        color(255, 255, 255, opacity)

        love.graphics.draw(
            img,
            x + w / 2,
            y + h / 2,
            0,
            scale,
            scale,
            iw / 2,
            ih / 2
        )
    end

    if not selected and not suppressTitle then
        color(3, 18, 38, opacity * 0.92)

        rect(
            x,
            y + h - 27,
            w,
            27
        )

        color(240, 251, 255, opacity)

        local title = truncateText(g.displayName or g.name, w - 8, font.tiny)
        love.graphics.setFont(font.tiny)
        love.graphics.print(title,
            x + (w - font.tiny:getWidth(title)) / 2,
            y + h - 24)
    end
end

--------------------------------------------------
-- DETACH GAME TITLE FROM CARD TO CENTER LABEL
--------------------------------------------------

local function drawMovingTitle(g, x, y, w, h, offset, opacity)
    -- 0 = inside the card, 1 = detached below the carousel.
    -- offsetFor() is animated, so the title follows the card smoothly.
    local t = smoothstep(1 - math.min(1, math.abs(offset) / 0.85))
    local startX = x + w / 2
    local startY = y + h - 24
    local centerX = startX + (W / 2 - startX) * t
    local titleY = startY + (350 - startY) * t
    local textScale = 1 + (24 / 13 - 1) * t
    local textWidth = (w - 6) + (560 - (w - 6)) * t
    local textHeight = font.tiny:getHeight() * textScale

    -- Card label backing disappears as the text leaves the card.
    if t < 1 then
        color(3, 18, 38, opacity * (1 - t) * 0.92)
        rect(x, y + h - 27, w, 27)
    end

    --if t > 0.80 then
    --    love.graphics.setColor(0.025,0.045,0.075,0.70 * opacity * ((t-0.80)/0.20))
    --    rect(34, titleY-5, W-68, 34, 7)
    --end
    color(240 + 15 * t, 251 + 4 * t, 255, opacity)
    love.graphics.setFont(font.tiny)
    love.graphics.push()
    love.graphics.translate(centerX, titleY)
    love.graphics.scale(textScale, textScale)
    local availableWidth = math.max(0, textWidth / textScale - 4)
    local title = truncateText(g.displayName or g.name, availableWidth, font.tiny)
    love.graphics.print(title, -font.tiny:getWidth(title) / 2, 0)
    love.graphics.pop()
end

--------------------------------------------------
-- GAME GALLERY
--------------------------------------------------



local function drawGrid()
    local g = group()
    if not g or #g.games == 0 then return end

    local cols, rows, pageSize = 5, 2, 10
    local count = #g.games

    local page = math.floor(
        (carousel.index - 1) / pageSize
    )

    local startIndex = page * pageSize + 1

    local cellW, cellH = 110, 142
    local left, top = 30, 103

    local selectedGame = g.games[carousel.index]

    local focusProgress = smoothstep(gridFocus.time / GRID_FOCUS_DURATION)
    local samePage = math.floor((gridFocus.from - 1) / pageSize) == page
    local focusSlot = carousel.index - startIndex
    if samePage then
        local fromSlot = gridFocus.from - startIndex
        local fromX = left + (fromSlot % cols) * 116
        local fromY = top + math.floor(fromSlot / cols) * 145
        local toX = left + (focusSlot % cols) * 116
        local toY = top + math.floor(focusSlot / cols) * 145
        local focusX = fromX + (toX - fromX) * focusProgress
        local focusY = fromY + (toY - fromY) * focusProgress
        -- Moving soft focus plate follows D-pad selection.
        color(100, 215, 255, 0.12)
        rect(focusX - 7, focusY - 7, cellW + 14, cellH - 2, 7)
    end

    --------------------------------------------------
    -- GAME GRID
    --------------------------------------------------

    for i = startIndex,
        math.min(count, startIndex + pageSize - 1) do

        local slot = i - startIndex

        local x = left + (slot % cols) * 116
        local y = top + math.floor(slot / cols) * 145

        local selected = (i == carousel.index)

        -- Focused cover gently pops up; other covers retain their positions.
        local focusAmount = selected and focusProgress or 0
        local scale = 1 + 0.035 * focusAmount
        local lift = 3 * focusAmount
        love.graphics.push()
        love.graphics.translate(x + cellW / 2, y + (cellH - 16) / 2 - lift)
        love.graphics.scale(scale, scale)
        love.graphics.translate(-cellW / 2, -(cellH - 16) / 2)
        drawCover(
            g.games[i],
            0, 0,
            cellW, cellH - 16,
            selected,
            1,
            true -- Grid titles are animated separately below.
        )
        -- Animate the title inside the same transform as its cover.
        -- Avoid intersectScissor: scissor coordinates are screen pixels,
        -- which can hide labels when the launcher is scaled or captured.
        local coverH = cellH - 16
        local titleProgress = smoothstep(gridTitleProgress[g.games[i]] or (selected and 1 or 0))
        local titleOpacity = (1 - titleProgress) * (1 - titleProgress)
        if titleOpacity > 0.001 then
            local stripY = coverH - 27
            local textY = stripY + 3 + 12 * titleProgress
            color(3, 18, 38, 0.92 * titleOpacity)
            rect(0, stripY, cellW, 27)
            color(240, 251, 255, titleOpacity)
            local title = truncateText(g.games[i].displayName or g.games[i].name, cellW - 8, font.tiny)
            love.graphics.setFont(font.tiny)
            love.graphics.print(title,
                (cellW - font.tiny:getWidth(title)) / 2,
                textY)
        end
        love.graphics.pop()
    end

    --------------------------------------------------
    -- BOTTOM: GAME NAME LEFT / METADATA RIGHT
    --------------------------------------------------

    if selectedGame then
        local title = tostring(
            selectedGame.displayName or
            selectedGame.name or ''
        )

        local version = tostring(
            selectedGame.version or ''
        )

        local vendor = tostring(
            selectedGame.vendor or ''
        )

        if version == '' then version = '-' end
        if vendor == '' then vendor = '-' end

        local fileSize = formatJarSize(selectedGame.path)

        local info = string.format(
            '%s | %s | %s | %d/%d',
            version,
            vendor,
            fileSize,
            carousel.index,
            count
        )

        local infoY = FOOTER_Y - 52

        -- Left: selected game title
        color(255, 255, 255)

        love.graphics.setFont(font.normal)
        love.graphics.print(truncateText(title, 245, font.normal), 20, infoY)

        -- Subtle separator
        color(110, 140, 165, 0.65)

        rect(
            273,
            infoY + 5,
            1,
            18
        )

        -- Right: version, vendor, size and index
        color(225, 235, 245)

        label(
            info,
            282,
            infoY + 6,
            340,
            'right',
            'tiny'
        )
    end
end



local function drawGallery()
    if layoutIndex == 2 and #groups > 0 then
        drawGrid()
        return
    end
    if #groups == 0 then
        color(238, 250, 255)

        label(
            'NO JAVA GAMES FOUND',
            70, 190, 500,
            'center', 'big'
        )

        label(
            'Add JAR games and restart JM',
            70, 229, 500,
            'center', 'normal'
        )

        return
    end

    local g = group()
    local count = #g.games

    if count == 0 then
        color(238, 250, 255)

        label(
            'NO GAMES IN ' .. g.label,
            70, 190, 500,
            'center', 'big'
        )

        return
    end

    local items = {}
    local seen = {}

    for relative = -3, 3 do
        local index =
            ((carousel.index - 1 + relative) % count) + 1

        if not seen[index] then
            seen[index] = true

            local offset =
                carousel:offsetFor(index, count)

            if math.abs(offset) < 3.7 then
                items[#items + 1] = {
                    game = g.games[index],
                    index = index,
                    offset = offset
                }
            end
        end
    end

    table.sort(items, function(a, b)
        return math.abs(a.offset) >
               math.abs(b.offset)
    end)

    for _, item in ipairs(items) do
        local o = item.offset
        local distance = math.abs(o)

        local scale =
            1 / (1 + distance * 0.34)

        local w = 166 * scale
        local h = 212 * scale

        local x =
            320 +
            o * 130 / (1 + distance * 0.18) -
            w / 2

        local y =
            120 + (1 - scale) * 93

        local opacity = math.max(
            0.28,
            1 - distance * 0.19
        )

        -- Each card floats with a different phase. Fade the motion
        -- during carousel movement to avoid a distracting wobble.
        local settled = math.max(0, 1 - math.min(1,
            math.abs(o - math.floor(o + 0.5)) * 2
        ))
        local floatOffset = math.sin(floatTime * FLOAT_SPEED + item.index * 1.7)
            * FLOAT_AMPLITUDE * (0.65 + 0.35 * settled)
        if introAnimation.active or exitAnimation.active then
            floatOffset = 0
        end
        y = y + floatOffset

        local intro = introAnimation.active
        local exiting = exitAnimation.active
        if intro or exiting then
            local t
            if exiting then
                t = 1 - math.min(1, exitAnimation.time / EXIT_DURATION)
            else
                t = math.min(1, introAnimation.time / INTRO_DURATION)
            end
            local dx, dy, angle, size, alpha = introTransform(o, t)
            local cx, cy = x + w / 2, y + h / 2
            love.graphics.push()
            love.graphics.translate(cx + dx, cy + dy)
            love.graphics.rotate(angle)
            love.graphics.scale(size, size)
            love.graphics.translate(-cx, -cy)
            drawCover(item.game, x, y, w, h, distance < 0.45,
                opacity * alpha, true)
            drawMovingTitle(item.game, x, y, w, h, o, opacity * alpha)
            love.graphics.pop()
        elseif launchAnimation.active and
           item.game == launchAnimation.selectedGame then
            -- Draw the card at its original proportions, then
            -- compress the entire card horizontally for a flip.
            local t = math.min(1, launchAnimation.time / LAUNCH_DURATION)
            local angle = t * math.pi * 2
            local flipX = math.cos(angle)
            local cx = x + w / 2

            love.graphics.push()
            love.graphics.translate(cx, 0)
            love.graphics.scale(flipX, 1)
            love.graphics.translate(-cx, 0)
            drawCover(item.game, x, y, w, h, true, opacity, true)
            love.graphics.pop()
            drawMovingTitle(item.game, x, y, w, h, o, opacity)
        else
            drawCover(
                item.game,
                x, y,
                w, h,
                distance < 0.45,
                opacity,
                true
            )
            drawMovingTitle(item.game, x, y, w, h, o, opacity)
        end
    end

    local selected = game()

    if not selected then
        return
    end

    color(186, 234, 255)

    label(
        (selected.version ~= '' and selected.version or '-') ..
        '   |   ' ..
        (selected.vendor ~= '' and selected.vendor or '-') ..
        '   |   ' ..
        formatJarSize(selected.path) ..
        '   |   ' ..
        carousel.index .. ' / ' .. count,
        40, 388, 560,
        'center', 'small'
    )
end

--------------------------------------------------
-- TAB TRANSITION
--------------------------------------------------

local function captureGallery()
    local canvas = love.graphics.newCanvas(W, H)
    local previousCanvas = love.graphics.getCanvas()

    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)

    love.graphics.push()
    love.graphics.origin()

    drawGallery()

    love.graphics.pop()
    love.graphics.setCanvas(previousCanvas)

    return canvas
end

local function switchGroup(delta)
    if #groups < 2 or tabTransition.active then
        return
    end

    local newIndex =
        ((groupIndex - 1 + delta) % #groups) + 1

    if newIndex == groupIndex then
        return
    end

    -- Save current tab's position before changing the active tab.
    rememberTabSelection()
    local oldCanvas = captureGallery()

    groupIndex = newIndex
    restoreTabSelection()
    gridFocus.from, gridFocus.to = carousel.index, carousel.index
    gridFocus.time = GRID_FOCUS_DURATION

    local newCanvas = captureGallery()

    tabTransition.oldCanvas = oldCanvas
    tabTransition.newCanvas = newCanvas
    tabTransition.time = 0
    tabTransition.direction = delta >= 0 and 1 or -1
    tabTransition.active = true
end

local function drawGalleryTransition()
    if not tabTransition.active then
        drawGallery()
        return
    end

    local progress = smoothstep(
        tabTransition.time / TAB_DURATION
    )

    local direction = tabTransition.direction

    local oldX =
        -direction * TAB_SLIDE * progress

    local newX =
        direction * TAB_SLIDE * (1 - progress)

    love.graphics.stencil(function()
        love.graphics.rectangle(
            'fill',
            0, 88,
            W, FOOTER_Y - 88
        )
    end, 'replace', 1)

    love.graphics.setStencilTest('greater', 0)

    if tabTransition.oldCanvas then
        love.graphics.setColor(
            1, 1, 1,
            1 - progress
        )

        love.graphics.draw(
            tabTransition.oldCanvas,
            oldX, 0
        )
    end

    if tabTransition.newCanvas then
        love.graphics.setColor(
            1, 1, 1,
            progress
        )

        love.graphics.draw(
            tabTransition.newCanvas,
            newX, 0
        )
    end

    love.graphics.setStencilTest()
    love.graphics.setColor(1, 1, 1, 1)
end

--------------------------------------------------
-- VERSION AND AUTHOR
--------------------------------------------------

local function drawVersionInfo()
    local y = FOOTER_Y - 19 - 3

    -- Same translucent white text across all themes.
    love.graphics.setColor(1, 1, 1, 0.60)
    label('v1.0.8', 15, y + 2, 61, 'center', 'tiny')
    label('by long-ngk', 88, y + 2, 180, 'left', 'tiny')
end

--------------------------------------------------
-- FOOTER
--------------------------------------------------

local function drawFooter()
    -- Fully opaque footer: legible on all seven illustrated backgrounds.
    love.graphics.setColor(0.035,0.055,0.085,1)
    rect(0,FOOTER_Y,W,FOOTER_H)
    local p = palettes[themes[themeIndex]] or palettes.Default
    love.graphics.setColor(p[1]/255,p[2]/255,p[3]/255,0.95)
    rect(0,FOOTER_Y,W,2)

    local padding = 8
    local w1 = (W-2*padding)/4
    local w2 = (W-2*padding)/4
    footerIcon(Icon.A,'30 FPS',padding,440,w1,16)
    footerIcon(Icon.X,'60 FPS',padding+w1,440,w1,16)
    footerResolution(padding+w1*2,440,w1)
    footerIcon(Icon.B,'Exit',padding+w1*3,440,w1,16)
    love.graphics.setColor(0.30,0.35,0.41,0.55)
    rect(12,459,W-24,1)
    footerText('SELECT','Scaling',padding,463,w2)
    footerText('START','Clear Keys',padding+w2,463,w2)
    footerText('D-PAD','Browse Games',padding+w2*2,463,w2)
    footerIcon(Icon.Y,'Appearance',padding+w2*3,461,w2,16)

    -- Notification
    if messageTime > 0 then
        color(4, 38, 72, 0.96)

        rect(
            100, 310,
            440, 36,
            7
        )

        color(250, 254, 255)

        label(
            message,
            108, 318, 424,
            'center', 'small'
        )
    end
end

--------------------------------------------------
-- LOAD ASSETS
--------------------------------------------------

local function loadImage(path)
    local ok, img = pcall(
        love.graphics.newImage,
        path
    )

    if ok and img then
        img:setFilter('nearest', 'nearest')
        return img
    end

    return nil
end

--------------------------------------------------
-- LOVE LOAD
--------------------------------------------------

function love.load()
    loadTheme()
    love.graphics.setDefaultFilter(
        'nearest',
        'nearest'
    )

    Font.Load()

    font.logo = love.graphics.newFont(FONT_PATH, 36)
    font.big = love.graphics.newFont(FONT_PATH, 24)
    font.normal = love.graphics.newFont(FONT_PATH, 17)
    font.small = love.graphics.newFont(FONT_PATH, 15)
    font.tiny = love.graphics.newFont(FONT_PATH, 13)

    -- Load background and JM logo
    applyThemeAssets()
    logoJM = loadImage(LOGO_PATH)

    GameManager.load()
    Covers.init()

    -- Cold Start or Resume
    initializeSelection()
    introAnimation.active = true
    introAnimation.time = 0

    if #groups > 0 then
        local tabW = 115

        tabIndicatorX =
            (W - tabW * #groups) / 2 +
            (groupIndex - 1) * tabW
    end
end

--------------------------------------------------
-- LOVE UPDATE
--------------------------------------------------

function love.update(dt)
    floatTime = floatTime + math.min(dt, 0.1)
    gridFocus.time = math.min(GRID_FOCUS_DURATION, gridFocus.time + dt)
    -- Animate title position independently so both the previous and the
    -- newly selected cover transition smoothly, including rapid D-pad input.
    if layoutIndex == 2 then
        local currentGroup = group()
        if currentGroup then
            local factor = math.min(1, math.max(0, dt) * GRID_TITLE_SPEED)
            for i, item in ipairs(currentGroup.games) do
                local target = (i == carousel.index) and 1 or 0
                local value = gridTitleProgress[item]
                if value == nil then value = target end
                value = value + (target - value) * factor
                if math.abs(value - target) < 0.001 then value = target end
                gridTitleProgress[item] = value
            end
        end
    end

    if exitAnimation.active then
        exitAnimation.time = math.min(EXIT_DURATION, exitAnimation.time + dt)
        if exitAnimation.time >= EXIT_DURATION and not exitAnimation.requested then
            exitAnimation.requested = true
            love.event.quit()
        end
    end

    if introAnimation.active then
        introAnimation.time = math.min(INTRO_DURATION,
            introAnimation.time + dt)
        if introAnimation.time >= INTRO_DURATION then
            introAnimation.active = false
        end
    end

    local g = group()

    if g and not tabTransition.active then
        carousel:update(
            dt,
            #g.games
        )
    end

    if tabTransition.active then
        tabTransition.time =
            tabTransition.time + dt

        if tabTransition.time >= TAB_DURATION then
            tabTransition.active = false
            tabTransition.oldCanvas = nil
            tabTransition.newCanvas = nil
        end
    end

    -- Animate tab indicator
    if #groups > 0 then
        local tabW = 115

        local targetX =
            (W - tabW * #groups) / 2 +
            (groupIndex - 1) * tabW

        if not tabIndicatorX then
            tabIndicatorX = targetX
        else
            local speed = math.min(
                1,
                dt * 15
            )

            tabIndicatorX =
                tabIndicatorX +
                (targetX - tabIndicatorX) * speed
        end
    end

    messageTime = math.max(
        0,
        messageTime - dt
    )

    if launchAnimation.active then
        launchAnimation.time = math.min(
            LAUNCH_DURATION,
            launchAnimation.time + dt
        )

        if launchAnimation.time >= LAUNCH_DURATION
            and not launchAnimation.launched then

            launchAnimation.launched = true

            local ok, err = GameManager.play(
                launchAnimation.selectedGame,
                launchAnimation.fps
            )

            if ok == false then
                launchAnimation.active = false
                launchAnimation.launched = false
                launchAnimation.time = 0
                notify(err or 'Cannot launch game')
            end
        end
    end
end

--------------------------------------------------
-- LOVE DRAW
--------------------------------------------------

function love.draw()
    local sw, sh = love.graphics.getDimensions()

    love.graphics.push()

    local s = math.min(
        sw / W,
        sh / H
    )

    love.graphics.translate(
        (sw - W * s) / 2,
        (sh - H * s) / 2
    )

    love.graphics.scale(s)

    drawBackground()
    drawHeader()
    drawGalleryTransition()
    drawVersionInfo()
    drawFooter()
    if themeMenu then
        color(3,10,22,0.93)
        rect(55,85,530,305,12)
        color(255,255,255)
        label('APPEARANCE',95,104,450,'center','big')
        local entries = {'Color tone', 'List style'}
        local values = {themes[themeIndex],layoutIndex==1 and 'Default' or 'Grid'}
        for i=1,2 do
            local y=174+(i-1)*79
            if menuRow==i then
                color(65,115,155,0.85)
                rect(85,y-9,470,57,8)
            end
            color(240,248,255)
            label(entries[i],103,y,220,'left','normal')
            label('< '..values[i]..' >',322,y,220,'center','normal')
        end
        color(190,215,235)
        label('LEFT / RIGHT: Change     A: Apply     B / Y: Back',75,349,490,'center','small')
    end

    -- Keep the final exit frame black until Love2D actually closes.
    if exitAnimation.active then
        local t = math.min(1, exitAnimation.time / EXIT_DURATION)
        love.graphics.setColor(0, 0, 0, smoothstep(t))
        love.graphics.rectangle('fill', 0, 0, W, H)
        love.graphics.setColor(1, 1, 1, 1)
    end

    -- Fade the whole launcher to black while the card flips.
    if launchAnimation.active then
        local t = math.min(1, launchAnimation.time / LAUNCH_DURATION)
        love.graphics.setColor(0, 0, 0, smoothstep(t))
        love.graphics.rectangle('fill', 0, 0, W, H)
        love.graphics.setColor(1, 1, 1, 1)
    end

    love.graphics.pop()
end

--------------------------------------------------
-- INPUT HANDLING
--------------------------------------------------

local function launchGame(fps)
    if tabTransition.active or launchAnimation.active then
        return
    end

    local selected = game()
    if not selected then return end

    -- Preserve the selection before starting the animation.
    if not saveLauncherState() then
        notify('Cannot save launcher state')
        return
    end

    launchAnimation.active = true
    launchAnimation.time = 0
    launchAnimation.fps = fps
    launchAnimation.selectedGame = selected
    launchAnimation.launched = false
end

local function onKey(key)
    if exitAnimation.active then return end
    if introAnimation.active then return end
    -- Prevent duplicate launches or navigation during the animation.
    if launchAnimation.active then return end

    if key == 'x' then
        themeMenu = not themeMenu
        return
    end
    if themeMenu then
        if key == 'escape' or key == 'b' or key == 'a' or key == 'return' then
            themeMenu=false
            saveTheme()
        elseif key == 'up' or key == 'down' then
            menuRow=3-menuRow
        elseif key == 'left' or key == 'right' then
            local delta=key=='right' and 1 or -1
            if menuRow==1 then
                themeIndex=((themeIndex-1+delta)%#themes)+1
                applyThemeAssets()
            else
                layoutIndex=((layoutIndex-1+delta)%2)+1
                gridFocus.from, gridFocus.to = carousel.index, carousel.index
                gridFocus.time = GRID_FOCUS_DURATION
            end
            saveTheme()
        end
        return
    end
    if key == 'escape' or key == 'a' then
        exitAnimation.active = true
        exitAnimation.time = 0
        exitAnimation.requested = false
        return
    end

    if key == 'select' then
        notify(
            GameManager.toggleScaling()
            and 'Scaling changed'
            or 'Scaling config not found'
        )
        return
    end

    if key == 'start' then
        notify(
            GameManager.clearMapping()
            and 'Key mapping cleared'
            or 'No key mapping to clear'
        )
        return
    end

    if #groups == 0 then
        return
    end

    local g = group()

    if layoutIndex == 2 and (key == 'left' or key == 'right' or key == 'up' or key == 'down') then
        if not tabTransition.active then
            local delta=({left=-1,right=1,up=-5,down=5})[key]
            local previousIndex = carousel.index
            carousel.index=math.max(1,math.min(#g.games,carousel.index+delta))
            if carousel.index ~= previousIndex then
                gridFocus.from = previousIndex
                gridFocus.to = carousel.index
                gridFocus.time = 0
            end
            carousel.position=carousel.index
            carousel.target=carousel.index
            carousel.velocity=0
        end
        return
    end
    if key == 'left' then
        if not tabTransition.active then
            carousel:move(-1, #g.games)
        end

    elseif key == 'right' then
        if not tabTransition.active then
            carousel:move(1, #g.games)
        end

    elseif key == 'up' or key == 'l1' then
        switchGroup(-1)

    elseif key == 'down' or key == 'r1' then
        switchGroup(1)

    elseif key == 'b' or key == 'return' then
        launchGame(30)

    elseif key == 'y' then
        launchGame(60)
    end
end

--------------------------------------------------
-- KEYBOARD INPUT
--------------------------------------------------

function love.keypressed(key)
    local keys = {
        space = 'a',
        backspace = 'b',
        tab = 'select',
        delete = 'start',
        pageup = 'l1',
        f2 = 'y',
        pagedown = 'r1'
    }

    onKey(keys[key] or key)
end

--------------------------------------------------
-- GAMEPAD INPUT
--------------------------------------------------

function love.gamepadpressed(_, button)
    -- Footer legend is physical: A=30 FPS, X=60 FPS, B=Exit, Y=Appearance.
    local keys = {
        dpleft = 'left',
        dpright = 'right',
        dpup = 'up',
        dpdown = 'down',
        leftshoulder = 'l1',
        rightshoulder = 'r1',
        back = 'select',
        start = 'start',
        a = 'return',
        b = 'escape',
        x = 'y',
        y = 'x'
    }

    onKey(keys[button] or button)
end
