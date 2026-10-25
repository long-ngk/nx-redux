local Carousel={}
Carousel.__index=Carousel
function Carousel.new()
    return setmetatable({index=1,position=1,velocity=0},Carousel)
end
function Carousel:reset()
    self.index=1;self.position=1;self.target=1;self.velocity=0
end
function Carousel:move(delta,count)
    if count<2 then return end
    self.index=((self.index-1+delta)%count)+1
    -- position is unbounded for seamless interpolation across the wrap
    self.position=self.position or 1
    self.target=(self.target or 1)+delta
end
function Carousel:update(dt,count)
    if count<1 then self.position=1;self.target=1;return end
    if not self.target then self.target=1 end
    local k=1-math.exp(-math.min(dt,0.1)*13)
    self.position=self.position+(self.target-self.position)*k
    if math.abs(self.target-self.position)<0.002 then self.position=self.target end
end
function Carousel:offsetFor(index,count)
    if count<1 then return 0 end
    local p=self.position
    local offset=(index-p)%count
    if offset>count/2 then offset=offset-count end
    return offset
end
return Carousel
