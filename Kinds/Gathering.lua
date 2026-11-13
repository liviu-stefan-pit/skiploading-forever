-- What the gathering kinds (ores, herbs ...) have in common: they are recorded when you cast the
-- profession's gathering spell on them, and their tooltip shows the skill they need against yours,
-- in the game's own difficulty colours.
--
-- ns.GatheringKind(def) registers a kind. On top of the fields ns.RegisterKind takes:
--   nodes       { [id] = { name, icon item id, skill needed } }
--   spells      the gathering spell's ids, every rank; the first one's name is matched as well
--   skill       the profession's English name, e.g. "Mining"
--   skillSpell  a spell named like the profession, for its name in the client's language
--   skillLine   the profession's skill line id
--   skillNames  optional: more English names the skill list may use for it
local _, ns = ...
local type, pcall = type, pcall

-- your current skill (with racial and gear bonuses), or nil if you don't have the profession.
-- The client offers this in different ways depending on its version, so try each; returns skill, source
local function PlayerSkill(def)
  local line = def.skillLine
  if C_SkillInfo and C_SkillInfo.GetSkillLineInfoByID then
    local ok, info = pcall(C_SkillInfo.GetSkillLineInfoByID, line)
    if ok and type(info) == "table" and info.rank then return info.rank + (info.modifier or 0), "C_SkillInfo" end
  end
  if C_TradeSkillUI and C_TradeSkillUI.GetProfessionInfoBySkillLineID then
    local ok, info = pcall(C_TradeSkillUI.GetProfessionInfoBySkillLineID, line)
    if ok and type(info) == "table" and (info.skillLevel or 0) > 0 then
      return info.skillLevel + (info.skillModifier or 0), "C_TradeSkillUI"
    end
  end
  if GetNumSkillLines and GetSkillLineInfo then
    for i = 1, GetNumSkillLines() do
      local name, isHeader, _, rank, _, modifier = GetSkillLineInfo(i)
      if not isHeader and def.skillNameSet[name] then return (rank or 0) + (modifier or 0), "skill list" end
    end
  end
end

-- the game's own difficulty colours: red can't, orange always skills up, yellow often, green rarely, grey never
local function Difficulty(req, skill)
  if not skill or skill < req then return 1, 0.13, 0.13 end
  if skill < req + 25 then return 1, 0.5, 0.25 end
  if skill < req + 50 then return 1, 1, 0 end
  if skill < req + 100 then return 0.25, 0.75, 0.25 end
  return 0.5, 0.5, 0.5
end

local function Tooltip(def, id)
  local n = def.nodes[id]
  local req = n and n[3]
  if not req then
    GameTooltip:AddLine(n and n[1] or tostring(id), 1, 0.82, 0)
    return
  end
  local skill = PlayerSkill(def)
  local r, g, b = Difficulty(req, skill)
  GameTooltip:AddLine(n[1], r, g, b)
  if skill then
    GameTooltip:AddLine(("Needs %s %d (yours: %d)"):format(def.skillName, req, skill), r, g, b)
  else
    GameTooltip:AddLine(("Needs %s %d (you don't have it)"):format(def.skillName, req), r, g, b)
  end
end

-- the skill-up filter: orange, yellow and green nodes can raise your skill; strict keeps orange and
-- yellow only. Red (can't gather) and grey (no skill-up) are hidden, and so is everything when you
-- don't have the profession. A node type with no known requirement is always kept.
local function Useful(def, strict)
  local skill, nodes, top = PlayerSkill(def), def.nodes, strict and 50 or 100
  local note = skill and (def.skillName .. " " .. skill) or ("no " .. def.skillName)
  return function(id)
    local n = nodes[id]
    local req = n and n[3]
    if not req then return true end
    return skill ~= nil and skill >= req and skill < req + top
  end, note
end

-- your skill went up (or you learned or dropped the profession): the filter may show other nodes now.
-- SKILL_LINES_CHANGED also fires for weapon skills, so only a change in this one counts.
local function SkillChanged(def)
  local skill = PlayerSkill(def)
  if skill ~= def.lastSkill then
    def.lastSkill = skill
    ns.UsefulChanged()
  end
end

function ns.GatheringKind(def)
  def.skillName = ns.SpellName(def.skillSpell) or def.skill
  def.skillNameSet = { [def.skill] = true, [def.skillName] = true }
  for _, name in ipairs(def.skillNames or {}) do def.skillNameSet[name] = true end
  local castName = ns.SpellName(def.spells[1])
  if castName then
    def.skillNameSet[castName] = true
    def.spellNames = { castName }
  end
  def.Tooltip = Tooltip
  def.Skill = PlayerSkill
  def.Useful = Useful
  def.events = def.events or {}
  def.events.SKILL_LINES_CHANGED = SkillChanged
  return ns.RegisterKind(def)
end

-- /sl skill: what the addon reads as your gathering skills, for when a tooltip looks wrong
ns.RegisterCommand("skill", function()
  for _, def in ipairs(ns.kinds) do
    if def.Skill then
      local skill, how = def.Skill(def)
      ns.say(def.skillName .. ": " .. (skill and (skill .. " (read from " .. how .. ")") or "not found"))
    end
  end
  local n = GetNumSkillLines and GetNumSkillLines()
  ns.say("skill list entries: " .. tostring(n))
  for i = 1, n or 0 do
    local name, isHeader, isExpanded, rank = GetSkillLineInfo(i)
    ns.say(("  %s%s %s"):format(tostring(name), isHeader and (isExpanded and " [header]" or " [header, collapsed]") or "",
      isHeader and "" or tostring(rank)))
  end
end)
