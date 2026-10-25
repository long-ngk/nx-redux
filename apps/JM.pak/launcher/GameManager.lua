local M = {}
M.groups = {}
local groupDefinitions = {
    {id='320',label='320x240',w=320,h=240},
    {id='240',label='240x320',w=240,h=320},
    {id='384',label='384x288',w=384,h=288},
    {id='128',label='128x128',w=128,h=128}
}
local function trim(s) return (s:gsub('^%s+',''):gsub('%s+$','')) end
-- Read exactly three metadata lines next to the JAR.
-- Keep the original filename-based name for config paths.
local function readInfo(jarPath)
    local infoPath = jarPath:gsub('%.[jJ][aA][rR]$', '.info')
    local f = io.open(infoPath, 'rb')
    if not f then return '', '', '' end
    local name = trim((f:read('*l') or ''):gsub('\r$', ''))
    local version = trim((f:read('*l') or ''):gsub('\r$', ''))
    local vendor = trim((f:read('*l') or ''):gsub('\r$', ''))
    f:close()
    return name, version, vendor
end
function M.load()
    -- Keep the original table reference used by main.lua.
    for i = #M.groups, 1, -1 do
        M.groups[i] = nil
    end
    for _, definition in ipairs(groupDefinitions) do
        local g = {
            id = definition.id,
            label = definition.label,
            w = definition.w,
            h = definition.h,
            games = {}
        }
        local f = io.open('/tmp/jar_' .. g.id, 'r')
        if f then
            for line in f:lines() do
                local path = trim(line)
                local filename = path:match('([^/]+)$') or path
                if path ~= '' and filename:lower():match('%.jar$') then
                    local name = filename:sub(1, -5)
                    local infoName, version, vendor = readInfo(path)
                    g.games[#g.games + 1] = {
                        name = name,
                        displayName = infoName ~= '' and infoName or name,
                        version = version,
                        vendor = vendor,
                        path = path,
                        type = g.id,
                        group = g
                    }
                end
            end
            f:close()
        end
        -- Hide tabs without games.
        if #g.games > 0 then
            M.groups[#M.groups + 1] = g
        end
    end
end
local function shellQuote(s) return "'"..tostring(s):gsub("'", "'\\''").."'" end
function M.play(game,fps)
    if not game then return end
    local g=game.group
    local dir=game.name..g.w..g.h
    local rootFile=io.open('/tmp/jm_dir','r')
    if not rootFile then return false,'Missing /tmp/jm_dir' end
    local root=trim(rootFile:read('*l') or '')
    rootFile:close()
    if root=='' then return false,'Empty /tmp/jm_dir' end
    local configDir=root..'/freej2me/config/'..dir
    local ok=os.execute('mkdir -p '..shellQuote(configDir))
    if ok==false or ok==nil then return false,'Cannot create config folder' end
    local f=io.open(configDir..'/game.conf','w')
    if not f then return false,'Cannot write game.conf' end
    f:write(string.format('width:%d\nfps:%d\nphone:n\nheight:%d\nsound:100\n',g.w,fps,g.h))
    f:close()
    local function write(path,value)
        local out=io.open(path,'w')
        if not out then return false end
        out:write(tostring(value),'\n'); out:close(); return true
    end
    if not (write('/tmp/jm_launch_w',g.w) and write('/tmp/jm_launch_h',g.h) and write('/tmp/jm_launch_p',game.path)) then
        return false,'Cannot write launch signals'
    end
    love.event.quit(2)
    return true
end
function M.toggleScaling()
    local f=io.open('/tmp/jm_dir','r')
    if not f then return false end
    local root=trim(f:read('*l') or '');f:close()
    if root=='' then return false end
    local path=root..'/freej2me/graphics.cfg'
    f=io.open(path,'r');local old=f and trim(f:read('*a') or '') or '0';if f then f:close() end
    f=io.open(path,'w');if not f then return false end
    f:write(old=='0' and '1' or '0');f:close();return true
end
function M.clearMapping()
    local f=io.open('/tmp/jm_dir','r');if not f then return false end
    local root=trim(f:read('*l') or '');f:close()
    if root=='' then return false end
    return os.remove(root..'/freej2me/input.cfg')
end
return M
