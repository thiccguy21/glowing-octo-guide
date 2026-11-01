--[[  PF Weapon Aim Crosshair v10  ------------------------------------------------
  A crosshair drawn where the player's weapon is aiming, configured from a tab in
  Matcha's own menu (UI.AddTab).

  AIM MODEL
    hip fire   rides the live weapon part in every pose - walk, sprint, reload,
               weapon swap. Nothing is latched or learned.
    aiming     PF fires along the camera view, so the marker uses the camera
               origin plus the barrel direction: centres, still tracks the gun.
    range      projected at the real raycast hit range, so it stays on the true
               trajectory instead of drifting outward at distance.
    fallback   only when the weapon part genuinely stops existing (dead,
               spectating, viewmodel unloaded) - a fixed offset, not the centre.

  Muzzle handling: the acceptance window below is a PICK heuristic only. Once a
  part is chosen it is trusted anywhere on or off screen, so a wide swing never
  snaps the marker back to the middle.

  Matcha notes: no Instance global (Drawing only). Glow is emulated by layering
  fatter, fainter copies of the shape behind it - Drawing has no blur.
  The UI mirror is wrapped in pcall: a widget read must never stop the crosshair.
  Stop: _G.PFWeaponAim.stop()
--------------------------------------------------------------------------------]]

if _G.PFWeaponAim and _G.PFWeaponAim.stop then _G.PFWeaponAim.stop() end

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")

local lp      = Players.LocalPlayer
local running = true

-- ================================== config =====================================
local CFG = {
    -- aim
    Enabled      = true,
    Mode         = "auto",   -- auto | hip | ads
    AnchorWeapon = true,
    UseHitRange  = true,
    NoReadOffset = true,
    HipDist      = 40,
    AdsScale     = 0.60,
    ScaleDist    = true,     -- size shrinks with distance
    -- shape
    Style        = "cross",  -- cross | x | circle | cross+circle | dot
    Size         = 1.00,
    Thick        = 1,
    Gap          = 4,
    Arm          = 5,
    Dot          = true,
    DotSize      = 1.2,
    Outline      = true,
    OutlineWidth = 1,        -- 1 = a hairline border; each step adds half a pixel
    Opacity      = 100,      -- percent, 0 = invisible
    OffX         = 0,        -- pixel nudge
    OffY         = 0,
    -- glow
    Glow         = false,
    GlowLayers   = 2,        -- 1..3
    GlowSpread   = 3,        -- px per layer
    GlowColor    = Color3.fromRGB(0, 255, 110),
    -- colours
    Color        = Color3.fromRGB(0, 255, 110),
    AdsColorOn   = false,
    AdsColor     = Color3.fromRGB(255, 70, 70),
    -- extras
    ShowRay      = false,
    LineGlow     = false,
    LineGlowWidth = 4,
    DebugText    = true,

    -- ADS detection (camera FieldOfView against the hip baseline)
    BaseFov      = 120,
    AdsEnter     = 5,
    AdsExit      = 2,
    AdsDebounce  = 0.12,

    -- fallback offset when there is no weapon read at all (view space studs)
    FallR        = 0.60,
    FallU        = -2.60,
    FallF        = 5.00,

    -- pick heuristic for choosing a muzzle part (view space studs). Wide on
    -- purpose: live gun parts read as low as 0.82 alignment and sit up to ~40
    -- studs out; a miss here is what dropped the marker onto the fallback.
    MuzMinFwd    = -2.0,
    MuzMaxFwd    = 40.0,
    MuzMaxAbove  = 4.0,
    MuzMaxBelow  = -12.0,
    AlignStrict  = 0.60,
    AlignKeep    = 0.20,
    -- trust bounds for a muzzle already chosen: deliberately huge, see header
    TrustMinFwd  = -40.0,
    TrustMaxFwd  = 400.0,
    TrustMaxPerp = 120.0,

    -- size response
    MaxRange     = 1000,
    MinHitRange  = 4,
    RefDist      = 60,
    SizeMin      = 0.45,
    SizeMax      = 2.20,
}

local GLOW_MAX = 6   -- more layers = a softer, rounder halo (this API has no blur)

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function alphaOf() return 1 - clamp(CFG.Opacity, 0, 100) / 100 end

-- ============================== overlay objects ================================
-- creation order is back-to-front: glow, then outline, then the shapes, because
-- ZIndex support is not guaranteed in this VM
local glowArms, glowRing = {}, {}
for k = 1, GLOW_MAX do
    glowArms[k] = {}
    for i = 1, 4 do
        local line = Drawing.new("Line")
        line.Visible = false
        glowArms[k][i] = line
    end
    local circle = Drawing.new("Circle")
    circle.NumSides, circle.Filled, circle.Visible = 32, false, false
    glowRing[k] = circle
end
local glowLine = {}
for k = 1, GLOW_MAX do
    local line = Drawing.new("Line")
    line.Visible = false
    glowLine[k] = line
end

local outlineArms = {}
for i = 1, 4 do
    local line = Drawing.new("Line")
    line.Thickness, line.Color, line.Visible = 3, Color3.fromRGB(0, 0, 0), false
    outlineArms[i] = line
end
local outlineCircle = Drawing.new("Circle")
outlineCircle.NumSides, outlineCircle.Filled = 32, false
outlineCircle.Color, outlineCircle.Visible = Color3.fromRGB(0, 0, 0), false

local arms = {}
for i = 1, 4 do
    local line = Drawing.new("Line")
    line.Thickness, line.Visible = 1, false
    arms[i] = line
end
local ring = Drawing.new("Circle")
ring.NumSides, ring.Filled, ring.Visible = 32, false, false

local dot = Drawing.new("Circle")
dot.NumSides, dot.Filled, dot.Visible = 16, true, false

local barrelLine = Drawing.new("Line")
barrelLine.Thickness, barrelLine.Transparency, barrelLine.Visible = 1, 0.6, false

local hud = Drawing.new("Text")
hud.Size, hud.Outline, hud.Position = 13, true, Vector2.new(30, 100)

local HAS_ZINDEX = pcall(function() dot.ZIndex = 1 end)
if HAS_ZINDEX then
    for k = 1, GLOW_MAX do
        for i = 1, 4 do glowArms[k][i].ZIndex = -1 end
        glowRing[k].ZIndex = -1
        glowLine[k].ZIndex = -1
    end
    for i = 1, 4 do outlineArms[i].ZIndex = 0 end
    outlineCircle.ZIndex = 0
    for i = 1, 4 do arms[i].ZIndex = 1 end
    ring.ZIndex, dot.ZIndex = 1, 1
    barrelLine.ZIndex = 1
end

-- Rebuilding is the only safe way to clear a fade. This VM renders a WRITTEN
-- Transparency of 0 as invisible and an unwritten one as visible, so "un-fading"
-- by writing a value is a coin flip, while a freshly created object is always
-- visible (exactly how the build behaved before any Transparency write existed).
local function makeLine(thickness)
    local l = Drawing.new("Line")
    l.Thickness, l.Visible = thickness, false
    return l
end

local function applyZIndex()
    if not HAS_ZINDEX then return end
    for k = 1, GLOW_MAX do
        for i = 1, 4 do glowArms[k][i].ZIndex = -1 end
        glowRing[k].ZIndex = -1
        glowLine[k].ZIndex = -1
    end
    for i = 1, 4 do outlineArms[i].ZIndex = 0 end
    outlineCircle.ZIndex = 0
    for i = 1, 4 do arms[i].ZIndex = 1 end
    ring.ZIndex, dot.ZIndex = 1, 1
    barrelLine.ZIndex = 1
end

local function rebuildShapes()
    for i = 1, 4 do
        arms[i]:Remove()
        arms[i] = makeLine(1)
    end
    for i = 1, 4 do
        outlineArms[i]:Remove()
        local l = makeLine(3)
        l.Color = Color3.fromRGB(0, 0, 0)
        outlineArms[i] = l
    end
    ring:Remove()
    ring = Drawing.new("Circle")
    ring.NumSides, ring.Filled, ring.Visible = 32, false, false
    outlineCircle:Remove()
    outlineCircle = Drawing.new("Circle")
    outlineCircle.NumSides, outlineCircle.Filled = 32, false
    outlineCircle.Color, outlineCircle.Visible = Color3.fromRGB(0, 0, 0), false
    dot:Remove()
    dot = Drawing.new("Circle")
    dot.NumSides, dot.Filled, dot.Visible = 16, true, false
    applyZIndex()
    print("PFWeaponAim: crosshair objects rebuilt (cleared stale fade)")
end

local shapesFaded = false

local function hideMarker()
    for i = 1, 4 do arms[i].Visible, outlineArms[i].Visible = false, false end
    ring.Visible, outlineCircle.Visible, dot.Visible = false, false, false
    for k = 1, GLOW_MAX do
        for i = 1, 4 do glowArms[k][i].Visible = false end
        glowRing[k].Visible = false
        glowLine[k].Visible = false
    end
    barrelLine.Visible = false
end

-- =========================== crosshair rendering ===============================
-- shape geometry for the current style, centred on (x, y)
local function shapeFor(x, y, gap, arm)
    local style = CFG.Style
    local coords, wantRing
    if style == "x" then
        local d, g = (gap + arm) * 0.7071, gap * 0.7071
        coords = {
            { x - d, y - d, x - g, y - g },
            { x + g, y + g, x + d, y + d },
            { x - d, y + d, x - g, y + g },
            { x + g, y - g, x + d, y - d },
        }
    elseif style == "circle" then
        wantRing = true
    elseif style == "cross+circle" then
        wantRing = true
        coords = {
            { x - gap - arm, y, x - gap, y },
            { x + gap, y, x + gap + arm, y },
            { x, y - gap - arm, x, y - gap },
            { x, y + gap, x, y + gap + arm },
        }
    elseif style == "dot" then
        coords = nil
    else
        coords = {
            { x - gap - arm, y, x - gap, y },
            { x + gap, y, x + gap + arm, y },
            { x, y - gap - arm, x, y - gap },
            { x, y + gap, x, y + gap + arm },
        }
    end
    return coords, wantRing, math.max(gap + arm, 2)
end

local function drawMarker(x, y, scale, color)
    scale = scale or 1
    x, y = x + CFG.OffX, y + CFG.OffY

    local gap   = CFG.Gap * scale
    local arm   = CFG.Arm * scale
    local thick = clamp(CFG.Thick * scale, 1, 6)
    local main  = alphaOf()

    -- clearing a fade means rebuilding, not writing a Transparency value
    if main == 0 and shapesFaded then
        shapesFaded = false
        rebuildShapes()
    elseif main > 0 then
        shapesFaded = true
    end

    for i = 1, 4 do
        arms[i].Visible, outlineArms[i].Visible = false, false
    end
    ring.Visible, outlineCircle.Visible, dot.Visible = false, false, false
    for k = 1, GLOW_MAX do
        for i = 1, 4 do glowArms[k][i].Visible = false end
        glowRing[k].Visible = false
    end

    local coords, wantRing, radius = shapeFor(x, y, gap, arm)

    -- glow: fatter, fainter copies behind the shape (no blur in this API)
    if CFG.Glow then
        local layers = clamp(CFG.GlowLayers, 1, GLOW_MAX)
        for k = 1, layers do
            -- outer layers are fatter and fainter, which reads as a soft halo
            local t = k / layers
            local w = thick + CFG.GlowSpread * k * 0.8
            local a = clamp(0.62 - 0.45 * t, 0.08, 0.75)
            if coords then
                for i = 1, 4 do
                    local g = glowArms[k][i]
                    g.From = Vector2.new(coords[i][1], coords[i][2])
                    g.To = Vector2.new(coords[i][3], coords[i][4])
                    g.Thickness, g.Color, g.Transparency, g.Visible = w, CFG.GlowColor, a, true
                end
            end
            if wantRing then
                local gr = glowRing[k]
                gr.Position = Vector2.new(x, y)
                gr.Radius = radius + k * CFG.GlowSpread * 0.5
                gr.Thickness, gr.Color, gr.Transparency, gr.Visible = w, CFG.GlowColor, a, true
            end
        end
    end

    -- outline: solid black behind the shape, and scaled WITH the marker so a
    -- small crosshair cannot be swallowed by a full-width outline
    -- A full pixel per step, scaled with the marker. Default 1 still reads as a
    -- hairline (the border is half the pad on each side), while higher steps are
    -- clearly heavier - half-pixel steps made the slider pointless.
    local outlinePad = math.max(0.5, CFG.OutlineWidth) * scale
    if CFG.Outline then
        if coords then
            for i = 1, 4 do
                outlineArms[i].From = Vector2.new(coords[i][1], coords[i][2])
                outlineArms[i].To = Vector2.new(coords[i][3], coords[i][4])
                outlineArms[i].Thickness = thick + outlinePad
                outlineArms[i].Visible = true
            end
        end
        if wantRing then
            outlineCircle.Position = Vector2.new(x, y)
            outlineCircle.Radius = radius + outlinePad * 0.5
            outlineCircle.Thickness = thick + outlinePad
            outlineCircle.Visible = true
        end
    end

    -- The shapes themselves. Transparency is written ONLY when a fade is asked
    -- for: this VM renders a written 0 as INVISIBLE, so writing it at full
    -- opacity made the coloured crosshair disappear and left only the outline.
    if coords then
        for i = 1, 4 do
            arms[i].From = Vector2.new(coords[i][1], coords[i][2])
            arms[i].To = Vector2.new(coords[i][3], coords[i][4])
            arms[i].Thickness, arms[i].Color, arms[i].Visible = thick, color, true
            if main > 0 then arms[i].Transparency = main end
        end
    end
    if wantRing then
        ring.Position = Vector2.new(x, y)
        ring.Radius = radius
        ring.Thickness, ring.Color, ring.Visible = thick, color, true
        if main > 0 then ring.Transparency = main end
    end

    -- the "dot" style implies the dot, else Dot=off would render nothing at all
    if CFG.Dot or CFG.Style == "dot" then
        dot.Position = Vector2.new(x, y)
        dot.Radius = clamp(CFG.DotSize * scale, 0.5, 8)
        dot.Color, dot.Visible = color, true
        if main > 0 then dot.Transparency = main end
    end
end

-- ================================== menu tab ===================================
local ID = {
    enabled = "pfaim_enabled", enabledKb = "pfaim_enabled_kb",
    mode = "pfaim_mode", anchor = "pfaim_anchor", hitrange = "pfaim_hitrange",
    noread = "pfaim_noread", hipdist = "pfaim_hipdist", adsScale = "pfaim_adsscale",
    scaledist = "pfaim_scaledist",
    style = "pfaim_style", size = "pfaim_size", thick = "pfaim_thick",
    gap = "pfaim_gap", arm = "pfaim_arm", dot = "pfaim_dot", dotcolor = "pfaim_dotcolor",
    dotsize = "pfaim_dotsize", outline = "pfaim_outline", outlinew = "pfaim_outlinew",
    opacity = "pfaim_opacity", offx = "pfaim_offx", offy = "pfaim_offy",
    fallr = "pfaim_fallr", fallu = "pfaim_fallu", fallf = "pfaim_fallf",
    glow = "pfaim_glow", glowcolor = "pfaim_glowcolor", glowlayers = "pfaim_glowlayers",
    glowspread = "pfaim_glowspread",
    adscolor = "pfaim_adscolor", adscolp = "pfaim_adscolour",
    ray = "pfaim_ray", lineglow = "pfaim_lineglow", linegloww = "pfaim_linegloww",
    debug = "pfaim_debug",
}

local MODES  = { "auto", "hip", "ads" }
local STYLES = { "cross", "x", "circle", "cross+circle", "dot" }

local function stateText()
    return "XAIR state mode=" .. CFG.Mode .. " anchor=" .. tostring(CFG.AnchorWeapon)
        .. " range=" .. tostring(CFG.UseHitRange) .. " style=" .. CFG.Style
        .. " hipdist=" .. math.floor(CFG.HipDist) .. " adsscale=" .. string.format("%.2f", CFG.AdsScale)
        .. " size=" .. string.format("%.2f", CFG.Size) .. " thick=" .. CFG.Thick
        .. " gap=" .. CFG.Gap .. " arm=" .. CFG.Arm
        .. " dot=" .. tostring(CFG.Dot) .. " dotsize=" .. string.format("%.1f", CFG.DotSize)
        .. " outline=" .. tostring(CFG.Outline) .. " ow=" .. CFG.OutlineWidth
        .. " opacity=" .. math.floor(CFG.Opacity) .. " off=" .. CFG.OffX .. "," .. CFG.OffY
        .. " glow=" .. tostring(CFG.Glow) .. " layers=" .. CFG.GlowLayers
        .. " spread=" .. CFG.GlowSpread
        .. " col=" .. string.format("%.2f/%.2f/%.2f", CFG.Color.R, CFG.Color.G, CFG.Color.B)
        .. " glowcol=" .. string.format("%.2f/%.2f/%.2f", CFG.GlowColor.R, CFG.GlowColor.G, CFG.GlowColor.B)
        .. " adscol=" .. string.format("%.2f/%.2f/%.2f", CFG.AdsColor.R, CFG.AdsColor.G, CFG.AdsColor.B)
        .. " adscolour=" .. tostring(CFG.AdsColorOn)
        .. " scaledist=" .. tostring(CFG.ScaleDist)
        .. " ray=" .. tostring(CFG.ShowRay) .. " lineglow=" .. tostring(CFG.LineGlow)
        .. " debug=" .. tostring(CFG.DebugText) .. " enabled=" .. tostring(CFG.Enabled)
end

local function resetAll()
    UI.SetValue(ID.enabled, true)
    UI.SetValue(ID.mode, 0)
    UI.SetValue(ID.anchor, true)
    UI.SetValue(ID.hitrange, true)
    UI.SetValue(ID.noread, true)
    UI.SetValue(ID.hipdist, 40)
    UI.SetValue(ID.adsScale, 0.60)
    UI.SetValue(ID.scaledist, true)
    UI.SetValue(ID.fallr, 0.6)
    UI.SetValue(ID.fallu, -2.6)
    UI.SetValue(ID.fallf, 5.0)
    UI.SetValue(ID.style, 0)
    UI.SetValue(ID.size, 1.0)
    UI.SetValue(ID.thick, 1)
    UI.SetValue(ID.gap, 4)
    UI.SetValue(ID.arm, 5)
    UI.SetValue(ID.dot, true)
    UI.SetValue(ID.dotsize, 1.2)
    UI.SetValue(ID.outline, true)
    UI.SetValue(ID.outlinew, 1)
    UI.SetValue(ID.opacity, 100)
    UI.SetValue(ID.offx, 0)
    UI.SetValue(ID.offy, 0)
    UI.SetValue(ID.glow, false)
    UI.SetValue(ID.glowlayers, 2)
    UI.SetValue(ID.glowspread, 3)
    UI.SetValue(ID.adscolor, false)
    UI.SetValue(ID.ray, false)
    UI.SetValue(ID.lineglow, false)
    UI.SetValue(ID.linegloww, 4)
    UI.SetValue(ID.debug, true)
    CFG.Color = Color3.fromRGB(0, 255, 110)
    CFG.GlowColor = Color3.fromRGB(0, 255, 110)
    CFG.AdsColor = Color3.fromRGB(255, 70, 70)
    print("PFWeaponAim: crosshair reset")
end

-- A combo widget left over from an older build keeps its OLD item list, which
-- silently re-maps every option (v9's 3-item list made "dot" read as "x").
-- Force the list to match this build.
local function syncCombo(combo, items)
    local ok, current = pcall(function() return combo:GetItems() end)
    if not ok or type(current) ~= "table" then return end
    local same = (#current == #items)
    if same then
        for i = 1, #items do
            if current[i] ~= items[i] then
                same = false
                break
            end
        end
    end
    if same then return end
    pcall(function()
        combo:Clear()
        for _, name in ipairs(items) do combo:Add(name) end
        combo:SetValue(0)
    end)
    print("PFWeaponAim: refreshed combo items to " .. table.concat(items, ", "))
end

-- Widgets are (RE)registered every frame this tab renders - that is the
-- documented pattern. Building a page only once left it blank when you switched
-- to it and back, because widget registration does not survive a page change.
-- Values live in the binding's store keyed by id, so re-registering does not
-- reset anything the user has set.
-- The panel is adaptive: a row that cannot affect the current mode is simply
-- not registered, so it disappears instead of sitting there doing nothing.
-- Values are kept in the binding's store by id, so a hidden row comes back with
-- whatever it was set to.
local TAB_NAME = "PF Weapon Aim"

-- Which rows SHOULD exist right now. This binding cannot disable or hide a
-- widget (its objects expose only __id/text/value) and a registered row survives
-- even if it stops being registered, so the only way to change the row set is to
-- rebuild the tab when this string changes.
local function rowSig()
    local style = CFG.Style
    local usesParts = (style == "cross" or style == "x" or style == "cross+circle")
    local usesRing = (style == "circle" or style == "cross+circle")
    local usesDot = CFG.Dot or style == "dot"
    return string.format("style=%s parts=%s ring=%s dot=%s outline=%s mode=%s noread=%s glow=%s lineglow=%s",
        style, tostring(usesParts), tostring(usesRing), tostring(usesDot),
        tostring(CFG.Outline), CFG.Mode, tostring(CFG.NoReadOffset),
        tostring(CFG.Glow), tostring(CFG.LineGlow))
end

local lastRowSig = nil
local probedWidget = false

-- One-shot look at what a widget object actually exposes: if this binding has a
-- disable/grey-out method, the conflicting rows can be disabled for real rather
-- than omitted.
local function probeWidget(kind, w)
    if probedWidget or w == nil then return end
    probedWidget = true
    local ok, fields = pcall(function()
        local t = {}
        for k, v in pairs(w) do t[#t + 1] = tostring(k) .. ":" .. type(v) end
        table.sort(t)
        return table.concat(t, ", ")
    end)
    print("XAIR widget(" .. kind .. ") fields: " .. tostring(fields))
    for _, m in ipairs({ "SetEnabled", "SetDisabled", "Disable", "Enable", "SetVisible", "Hide", "SetActive", "SetGrayed" }) do
        local f = w[m]
        if type(f) == "function" then print("XAIR widget method available: " .. m) end
    end
end

local function buildUI(tab)
    local style = CFG.Style
    local usesParts = (style == "cross" or style == "x" or style == "cross+circle")
    local usesRing = (style == "circle" or style == "cross+circle")
    local usesDot = CFG.Dot or style == "dot"


    -- heartbeat: proves whether this callback runs at all (it only ticks while
    -- the menu is rendering this tab)
    uiTicks = (uiTicks or 0) + 1
    if uiTicks % 180 == 1 then
        print("XAIR ui alive " .. uiTicks)
    end

    -- ============================ AIM  (left) ================================
    local aim = tab:Section("Aim", "Left", { "Aiming", "Advanced" })
    if aim.page == 0 then
        aim:Toggle(ID.enabled, "Crosshair", true)
        local kb = aim:Keybind(ID.enabledKb, 0, "toggle")
        kb:AddToHotkey("PF Crosshair", ID.enabled)
        aim:Tip("bind a key to toggle the crosshair in game")
        syncCombo(aim:Combo(ID.mode, "Aim mode", MODES, 0), MODES)

        if CFG.Mode == "ads" then
            aim:Text("Forced ADS: hip distance does not apply.")
        else
            aim:SliderInt(ID.hipdist, "Hip distance", 5, 500, 40)
        end

        if CFG.Mode == "hip" then
            aim:Text("Forced hip fire: ADS size does not apply.")
        else
            aim:SliderFloat(ID.adsScale, "ADS size", 0.2, 1.5, 0.60, "%.2f")
        end

        aim:Toggle(ID.anchor, "Anchor to weapon", true)
        aim:Tip("off = plain camera-axis marker")
        aim:Toggle(ID.scaledist, "Scale with distance", true)
    elseif aim.page == 1 then
        aim:Toggle(ID.hitrange, "Use hit range", true)
        aim:Tip("project at the real hit range, not a fixed distance")
        aim:Toggle(ID.noread, "No-read fallback", true)
        aim:Tip("only used when no weapon part can be read at all")
        if CFG.NoReadOffset then
            aim:SliderFloat(ID.fallr, "Fallback right", -12, 12, 0.6, "%.1f")
            aim:SliderFloat(ID.fallu, "Fallback up", -12, 12, -2.6, "%.1f")
            aim:SliderFloat(ID.fallf, "Fallback forward", 0, 40, 5.0, "%.1f")
            aim:Tip("only used in the no-read case above")
        else
            aim:Text("Fallback offsets are unused while the fallback is off.")
        end
    end

    -- ========================= CROSSHAIR  (left) =============================
    local look = tab:Section("Crosshair", "Left", { "Shape", "Colour & Glow" })
    if look.page == 0 then
        local styleCombo = look:Combo(ID.style, "Style", STYLES, 0)
        probeWidget("combo", styleCombo)
        syncCombo(styleCombo, STYLES)
        look:SliderFloat(ID.size, "Size", 0.2, 3.0, 1.00, "%.2f")

        if style == "dot" then
            look:Text("Dot style: thickness, gap, arms and outline do not apply.")
        else
            look:SliderInt(ID.thick, "Thickness", 1, 6, 1)
        end

        -- gap and arm length drive the arm offset AND the circle radius
        if usesParts or usesRing then
            look:SliderInt(ID.gap, "Gap", 0, 20, 4)
        end
        if usesParts then
            look:SliderInt(ID.arm, "Arm length", 0, 24, 5)
        end

        look:Toggle(ID.dot, "Centre dot", true)
        look:ColorPicker(ID.dotcolor, 0, 1, 0.43, 1, function(col)
            if col ~= nil and type(col) ~= "number" then CFG.Color = col end
        end)

        if usesDot then
            look:SliderFloat(ID.dotsize, "Dot size", 0.4, 4.0, 1.2, "%.1f")
        end

        if style ~= "dot" then
            look:Toggle(ID.outline, "Outline", true)
            if CFG.Outline then
                look:SliderInt(ID.outlinew, "Outline width", 1, 6, 1)
            end
        end

        look:SliderInt(ID.opacity, "Opacity %", 10, 100, 100)
        look:SliderInt(ID.offx, "Offset X", -60, 60, 0)
        look:SliderInt(ID.offy, "Offset Y", -60, 60, 0)
    elseif look.page == 1 then
        look:Toggle(ID.glow, "Crosshair glow", false)
        look:ColorPicker(ID.glowcolor, 0, 1, 0.43, 1, function(col)
            if col ~= nil and type(col) ~= "number" then CFG.GlowColor = col end
        end)
        if CFG.Glow then
            look:SliderInt(ID.glowlayers, "Glow layers", 1, GLOW_MAX, 4)
            look:SliderInt(ID.glowspread, "Glow spread", 1, 12, 4)
            look:Tip("layered copies behind the shape - this API has no real blur")
        else
            look:Text("Glow is off: turn it on to tune layers and spread.")
        end
        look:Toggle(ID.adscolor, "Separate ADS colour", false)
        look:ColorPicker(ID.adscolp, 1, 0.27, 0.27, 1, function(col)
            if col ~= nil and type(col) ~= "number" then CFG.AdsColor = col end
        end)
        look:Tip("overrides the crosshair colour while aiming")
    end

    -- ============================ EXTRAS  (right) ============================
    local misc = tab:Section("Extras", "Right")
    misc:Toggle(ID.ray, "Barrel line")
    misc:Toggle(ID.lineglow, "Line glow")
    if CFG.LineGlow then
        misc:SliderInt(ID.linegloww, "Line glow width", 1, 10, 4)
    end
    misc:Toggle(ID.debug, "Debug text")
    misc:Tip("the small tag readout near the top-left")
    misc:Text("Crosshair is a Drawing overlay.")
    misc:Text("This panel is Matcha's own menu.")
    misc:Button("Reset crosshair", resetAll)
    misc:Button("Print live state", function() print(stateText()) end)
end

local function readBool(id, fallback)
    local v = UI.GetValue(id)
    if v == nil then return fallback end
    return not not v
end

local function readNum(id, fallback)
    local v = UI.GetValue(id)
    if type(v) == "number" then return v end
    return fallback
end

-- A colour picker reads back as FOUR NUMBERS (r, g, b, a), not a Color3. And
-- this VM's Color3.new takes 0-255: the fromRGB default rendered green while
-- Color3.new(0, 1, 0.0145) rendered BLACK. Normalise whatever range the picker
-- hands back into 0-255 and always build the colour with fromRGB.
local function chan255(v)
    v = tonumber(v) or 0
    if v <= 1.0001 then return clamp(v, 0, 1) * 255 end
    return clamp(v, 0, 255)
end

local function readColor(id, fallback)
    local r, g, b = UI.GetValue(id)
    if type(r) == "number" and type(g) == "number" and type(b) == "number" then
        return Color3.fromRGB(chan255(r), chan255(g), chan255(b))
    elseif r ~= nil and type(r) ~= "number" then
        return r
    end
    return fallback
end

local function mirrorFromUI()
    CFG.Enabled      = readBool(ID.enabled, CFG.Enabled)
    CFG.AnchorWeapon = readBool(ID.anchor, CFG.AnchorWeapon)
    CFG.UseHitRange  = readBool(ID.hitrange, CFG.UseHitRange)
    CFG.NoReadOffset = readBool(ID.noread, CFG.NoReadOffset)
    CFG.ScaleDist    = readBool(ID.scaledist, CFG.ScaleDist)
    CFG.Dot          = readBool(ID.dot, CFG.Dot)
    CFG.Outline      = readBool(ID.outline, CFG.Outline)
    CFG.Glow         = readBool(ID.glow, CFG.Glow)
    CFG.AdsColorOn   = readBool(ID.adscolor, CFG.AdsColorOn)
    CFG.ShowRay      = readBool(ID.ray, CFG.ShowRay)
    CFG.LineGlow     = readBool(ID.lineglow, CFG.LineGlow)
    CFG.DebugText    = readBool(ID.debug, CFG.DebugText)

    CFG.HipDist = clamp(readNum(ID.hipdist, CFG.HipDist), 5, 500)
    CFG.AdsScale = clamp(readNum(ID.adsScale, CFG.AdsScale), 0.2, 1.5)
    CFG.Size = clamp(readNum(ID.size, CFG.Size), 0.2, 3.0)
    CFG.Thick = clamp(readNum(ID.thick, CFG.Thick), 1, 6)
    CFG.Gap = clamp(readNum(ID.gap, CFG.Gap), 0, 20)
    CFG.Arm = clamp(readNum(ID.arm, CFG.Arm), 0, 24)
    CFG.DotSize = clamp(readNum(ID.dotsize, CFG.DotSize), 0.4, 4.0)
    CFG.OutlineWidth = clamp(readNum(ID.outlinew, CFG.OutlineWidth), 1, 6)
    CFG.Opacity = clamp(readNum(ID.opacity, CFG.Opacity), 10, 100)
    CFG.OffX = clamp(readNum(ID.offx, CFG.OffX), -60, 60)
    CFG.OffY = clamp(readNum(ID.offy, CFG.OffY), -60, 60)
    CFG.GlowLayers = clamp(readNum(ID.glowlayers, CFG.GlowLayers), 1, GLOW_MAX)
    CFG.GlowSpread = clamp(readNum(ID.glowspread, CFG.GlowSpread), 1, 10)
    CFG.LineGlowWidth = clamp(readNum(ID.linegloww, CFG.LineGlowWidth), 1, 10)
    CFG.FallR = clamp(readNum(ID.fallr, CFG.FallR), -12, 12)
    CFG.FallU = clamp(readNum(ID.fallu, CFG.FallU), -12, 12)
    CFG.FallF = clamp(readNum(ID.fallf, CFG.FallF), 0, 40)

    local mode = readNum(ID.mode, nil)
    if mode then CFG.Mode = MODES[(math.floor(mode) % #MODES) + 1] or CFG.Mode end
    local style = readNum(ID.style, nil)
    if style then CFG.Style = STYLES[(math.floor(style) % #STYLES) + 1] or CFG.Style end

    CFG.Color     = readColor(ID.dotcolor, CFG.Color)
    CFG.GlowColor = readColor(ID.glowcolor, CFG.GlowColor)
    CFG.AdsColor  = readColor(ID.adscolp, CFG.AdsColor)
end

-- Two behaviours are documented for the tab callback: "runs every frame" and
-- "runs when the menu renders the tab". Build once either way, and keep the
-- per-frame mirror in the render loop, which is always running.
UI.AddTab(TAB_NAME, function(tab)
    buildUI(tab)
end)

-- ============================== weapon state ===================================
-- arm / hand accessory names that must never be mistaken for a muzzle
local BAD_NAMES = {
    ["Sleeves"] = true, ["SkinTone"] = true, ["Arm"] = true, ["Watch"] = true,
    ["Right Arm"] = true, ["Left Arm"] = true,
    ["RightHand"] = true, ["LeftHand"] = true,
}

local S = { cam = nil, muzzle = nil, pinned = nil, rayParams = nil, charAnchor = nil }

local function viewOffset(cam, part)
    local frame = cam.CFrame
    local off = part.Position - frame.Position
    return off:Dot(frame.LookVector), off:Dot(frame.RightVector), off:Dot(frame.UpVector)
end

local function insideWindow(f, u)
    return f > CFG.MuzMinFwd and f < CFG.MuzMaxFwd
        and u < CFG.MuzMaxAbove and u > CFG.MuzMaxBelow
end

local function trusted(f, u)
    return f > CFG.TrustMinFwd and f < CFG.TrustMaxFwd and math.abs(u) < CFG.TrustMaxPerp
end

local function scanMuzzle(cam)
    local cv, upv = cam.CFrame.LookVector, cam.CFrame.UpVector

    local pinned = S.pinned
    if pinned and pinned.Parent and pinned:IsDescendantOf(cam) then
        local f, _, u = viewOffset(cam, pinned)
        if pinned.CFrame.LookVector:Dot(cv) > CFG.AlignKeep and trusted(f, u) then
            return pinned
        end
    end
    S.pinned = nil

    local best, bestFwd = nil, -1e9
    local stack, guard = { cam }, 0
    while #stack > 0 and guard < 400 do
        guard = guard + 1
        local node = table.remove(stack)
        for _, ch in ipairs(node:GetChildren()) do
            if ch.ClassName == "Model" or ch.ClassName == "Folder" then
                stack[#stack + 1] = ch
            elseif ch.ClassName == "Part" or ch.ClassName == "MeshPart" then
                local name = ch.Name
                -- arm/skin parts win a naive front-most pick: exclude them
                if node ~= cam and not BAD_NAMES[name] then
                    local f, _, u = viewOffset(cam, ch)
                    if insideWindow(f, u)
                        and ch.CFrame.LookVector:Dot(cv) > CFG.AlignStrict
                        and f > bestFwd then
                        best, bestFwd = ch, f
                    end
                end
            end
        end
    end
    S.pinned = best
    return best
end

task.spawn(function()
    local lastTool = nil
    while running do
        local cam = workspace.CurrentCamera
        S.cam = cam
        if cam then
            local char = lp.Character
            local tool = char and char:FindFirstChildOfClass("Tool")
            local toolName = tool and tool.Name or "none"
            if lastTool ~= nil and toolName ~= lastTool then
                S.pinned = nil                 -- new weapon: re-pick, nothing else
                print("XAIR weapon: " .. toolName)
            end
            lastTool = toolName
            S.muzzle = scanMuzzle(cam)

            -- If the viewmodel could not be read, use the weapon the character
            -- is actually holding before giving up on a fixed offset.
            S.charAnchor = nil
            if not S.muzzle and char then
                local tool = char:FindFirstChildOfClass("Tool")
                local handle = nil
                if tool then
                    for _, c in ipairs(tool:GetChildren()) do
                        if c.ClassName == "Part" or c.ClassName == "MeshPart" then
                            handle = handle or c
                        end
                    end
                end
                S.charAnchor = handle
                    or char:FindFirstChild("Right Arm") or char:FindFirstChild("RightHand")
                    or char:FindFirstChild("RightUpperArm")
            end
        end

        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        params.FilterDescendantsInstances = { cam, lp.Character }
        params.IgnoreWater = true
        S.rayParams = params

        task.wait(0.15)
    end
end)

-- =============================== render loop ===================================
local adsState, adsPending, adsPendingSince = false, nil, 0
local lastTag = nil
local mirrorWarned = false

local function resolveAds(fov)
    local want
    if CFG.Mode == "hip" then
        want = false
    elseif CFG.Mode == "ads" then
        want = true
    elseif fov then
        want = adsState and (fov < CFG.BaseFov - CFG.AdsExit) or (fov <= CFG.BaseFov - CFG.AdsEnter)
    end

    if want ~= nil and want ~= adsState then
        if adsPending == want then
            if tick() - adsPendingSince >= CFG.AdsDebounce then
                adsState, adsPending = want, nil
            end
        else
            adsPending, adsPendingSince = want, tick()
        end
    else
        adsPending = nil
    end
    return adsState
end

local conn = RunService.RenderStepped:Connect(function()
    -- the mirror is on the critical path: one bad widget read must never stop
    -- the crosshair from drawing, and it is reported once rather than every frame
    local okMirror, mirrorErr = pcall(mirrorFromUI)
    if not okMirror and not mirrorWarned then
        mirrorWarned = true
        print("XAIR mirror error: " .. tostring(mirrorErr))
    end

    -- rebuild the panel when the set of rows that should exist changes: this
    -- binding keeps a row alive once registered and offers no way to disable it
    local sig = rowSig()
    if sig ~= lastRowSig then
        lastRowSig = sig
        pcall(function()
            UI.RemoveTab(TAB_NAME)
            UI.AddTab(TAB_NAME, buildUI)
        end)
        print("XAIR panel rebuilt: " .. sig)
    end

    local cam = S.cam or workspace.CurrentCamera
    if not cam then return end

    local frame = cam.CFrame
    local cp, cv = frame.Position, frame.LookVector
    local right, up = frame.RightVector, frame.UpVector
    local fov = cam.FieldOfView

    if not CFG.Enabled then
        hideMarker()
        hud.Visible = false
        return
    end

    local ads = resolveAds(fov)
    local color = (CFG.AdsColorOn and ads) and CFG.AdsColor or CFG.Color

    local muz, muzDir = nil, nil
    local part = S.muzzle
    if part and part.Parent and part:IsDescendantOf(cam) then
        local f, _, u = viewOffset(cam, part)
        if trusted(f, u) then
            muz, muzDir = part, part.CFrame.LookVector
        end
    end

    local origin, dir
    if not CFG.AnchorWeapon then
        origin, dir = cp, cv
    elseif ads then
        origin, dir = cp, muzDir or cv
    elseif muz then
        origin, dir = muz.Position, muzDir
    elseif S.charAnchor and S.charAnchor.Parent then
        -- the weapon the character is holding, in world space: keeps tracking
        -- when the camera viewmodel cannot be read instead of snapping away
        origin, dir = S.charAnchor.Position, cv
    elseif CFG.NoReadOffset then
        origin = cp + cv * CFG.FallF + right * CFG.FallR + up * CFG.FallU
        dir = cv
    else
        origin, dir = cp, cv
    end

    local fixedDist = ads and CFG.AdsDist or CFG.HipDist
    local hit = S.rayParams and workspace:Raycast(origin, dir * CFG.MaxRange, S.rayParams) or nil

    -- a point on the weapon ray projects differently depending on how far along
    -- it sits, so use the real hit range or the marker drifts at distance
    local distance = fixedDist
    if CFG.UseHitRange and hit and hit.Position then
        distance = clamp(hit.Distance, CFG.MinHitRange, CFG.MaxRange)
    end

    local scale = CFG.ScaleDist
        and clamp(CFG.RefDist / math.max(distance, 1), CFG.SizeMin, CFG.SizeMax) or 1
    scale = scale * CFG.Size
    if ads then scale = scale * CFG.AdsScale end

    local screen, visible = WorldToScreen(origin + dir * distance)
    if not visible then
        hideMarker()
    else
        drawMarker(screen.X, screen.Y, scale, color)

        -- reset every frame: a branch that only ever turned this ON left the last
        -- drawn line on screen forever once the toggle went off
        barrelLine.Visible = false
        for k = 1, GLOW_MAX do glowLine[k].Visible = false end

        if CFG.ShowRay then
            local from, fromVisible = WorldToScreen(origin + dir)
            if fromVisible then
                local lineAlpha = alphaOf()
                if CFG.LineGlow then
                    for k = 1, GLOW_MAX do
                        local g = glowLine[k]
                        g.From = Vector2.new(from.X, from.Y)
                        g.To = Vector2.new(screen.X, screen.Y)
                        g.Thickness = 1 + k * CFG.LineGlowWidth
                        g.Color = CFG.GlowColor
                        g.Transparency = clamp(1 - k * 0.18, 0.1, 0.8)
                        g.Visible = true
                    end
                end
                barrelLine.From = Vector2.new(from.X, from.Y)
                barrelLine.To = Vector2.new(screen.X, screen.Y)
                barrelLine.Color = color
                if lineAlpha > 0 then barrelLine.Transparency = lineAlpha end
                barrelLine.Visible = true
            end
        end
    end

    local pose = ads and "ADS" or (muz and "HIP" or "NO-READ")
    local anchor = not CFG.AnchorWeapon and "cam"
        or (ads and "cam+barrel" or (muz and "gun"
        or (S.charAnchor and S.charAnchor.Parent and "held"
        or (CFG.NoReadOffset and "fixed" or "cam"))))
    local tag = pose .. "|" .. CFG.Mode .. "|" .. anchor
    if tag ~= lastTag then
        lastTag = tag
        print("XAIR " .. tag .. " fov " .. tostring(fov and math.floor(fov) or "?"))
    end

    hud.Color = color
    -- outline thickness = thick + OutlineWidth * scale, so show both numbers
    hud.Text = tag .. "  " .. CFG.Style .. "  "
        .. (hit and ("range " .. math.floor(distance)) or "no hit")
        .. "  ow" .. CFG.OutlineWidth .. " x" .. string.format("%.2f", scale)
    hud.Visible = CFG.DebugText
end)

-- ================================= teardown ====================================
_G.PFWeaponAim = {
    state = function() print(stateText()) end,

    reset = resetAll,

    stop = function()
        running = false
        conn:Disconnect()
        pcall(function() UI.RemoveTab("PF Weapon Aim") end)
        for i = 1, 4 do arms[i]:Remove(); outlineArms[i]:Remove() end
        for k = 1, GLOW_MAX do
            for i = 1, 4 do glowArms[k][i]:Remove() end
            glowRing[k]:Remove()
            glowLine[k]:Remove()
        end
        ring:Remove(); outlineCircle:Remove(); dot:Remove()
        barrelLine:Remove(); hud:Remove()
    end,
}

print("PFWeaponAim v10 loaded | glow, styles, opacity, offsets")