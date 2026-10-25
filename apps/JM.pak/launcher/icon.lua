local love = require("love")

local Icon = {}

Icon.Search = love.graphics.newImage("Assets/Icon/ic_search.png")
Icon.A = love.graphics.newImage("Assets/Icon/ic_a.png")
Icon.B = love.graphics.newImage("Assets/Icon/ic_b.png")
Icon.X = love.graphics.newImage("Assets/Icon/ic_x.png")
Icon.Y = love.graphics.newImage("Assets/Icon/ic_y.png")
Icon.Select = love.graphics.newImage("Assets/Icon/ic_select.png")
Icon.Start = love.graphics.newImage("Assets/Icon/ic_start.png")
Icon.L1 = love.graphics.newImage("Assets/Icon/ic_l1.png")
Icon.R1 = love.graphics.newImage("Assets/Icon/ic_r1.png")
Icon.Thumbnail = love.graphics.newImage("Assets/Icon/ic_thumbnail.png")

local names = {Search='ic_search.png',A='ic_a.png',B='ic_b.png',X='ic_x.png',Y='ic_y.png',Select='ic_select.png',Start='ic_start.png',L1='ic_l1.png',R1='ic_r1.png',Thumbnail='ic_thumbnail.png'}
function Icon.setTheme(theme)
    for key, filename in pairs(names) do
        local path = theme == 'Default' and ('Assets/Icon/'..filename) or ('Assets/Themes/'..theme..'/Icon/'..filename)
        if not love.filesystem.getInfo(path) then path = 'Assets/Icon/'..filename end
        Icon[key] = love.graphics.newImage(path)
    end
end
return Icon