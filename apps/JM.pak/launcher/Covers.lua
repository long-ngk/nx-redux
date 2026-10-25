
local Covers = {
    cache = {},
    tick = 0,
    maxEntries = 13
}

local extensions = {
    '.png', '.jpg', '.jpeg',
    '.PNG', '.JPG', '.JPEG'
}

local function exists(path)
    local f = io.open(path, 'rb')

    if f then
        f:close()
        return true
    end

    return false
end

-- Automatically select image filtering
local function applyFilter(image)
    if not image then
        return
    end

    local w, h = image:getDimensions()

    if w <= 128 or h <= 128 then
        image:setFilter('nearest', 'nearest')
    else
        image:setFilter('linear', 'linear')
    end
end

local function loadExternal(path)
    local f = io.open(path, 'rb')

    if not f then
        return nil
    end

    local data = f:read('*a')
    f:close()

    if not data or #data == 0 then
        return nil
    end

    local ok, image = pcall(function()
        local filename =
            path:match('[^/]+$') or 'cover.png'

        local fd = love.filesystem.newFileData(
            data,
            filename
        )

        return love.graphics.newImage(fd)
    end)

    if ok and image then
        applyFilter(image)
        return image
    end

    return nil
end

function Covers.get(game)
    if not game then
        return nil
    end

    local key = game.path

    Covers.tick = Covers.tick + 1

    local cached = Covers.cache[key]

    if cached then
        cached.used = Covers.tick
        return cached.image
    end

    local base = key:gsub('%.[jJ][aA][rR]$', '')

    local image

    for _, ext in ipairs(extensions) do
        local path = base .. ext

        if exists(path) then
            image = loadExternal(path)

            if image then
                break
            end
        end
    end

    if not image then
        image = Covers.default
    end

    Covers.cache[key] = {
        image = image,
        used = Covers.tick
    }

    -- LRU cache eviction
    local n = 0
    local oldest, oldTime

    for k, v in pairs(Covers.cache) do
        n = n + 1

        if not oldTime or v.used < oldTime then
            oldest = k
            oldTime = v.used
        end
    end

    if n > Covers.maxEntries then
        Covers.cache[oldest] = nil
    end

    return image
end

function Covers.init()
    local ok, img = pcall(
        love.graphics.newImage,
        'Assets/default_cover.png'
    )

    if ok and img then
        Covers.default = img
        applyFilter(Covers.default)
    end
end

return Covers
