-------------------------------------------------------------------------------
--                      GearScore - Auto Party/Raid Scanner                  --
--                                                                           --
-- Periodically inspects party/raid members and saves their GearScore to    --
-- the database. Scans one member per tick, cycling through the group until  --
-- all members are in the database, then stops automatically.               --
--                                                                           --
-- HOW TO INSTALL:                                                           --
--   1. Drop this file in your GearScore addon folder.                       --
--   2. Add "GearScore_AutoScan.lua" to GearScore.toc (after GearScore.lua). --
--   3. Reload UI.                                                           --
--                                                                           --
-- SLASH COMMANDS (added by this file):                                      --
--   /gsautoscan          - Start the periodic scanner                       --
--   /gsautoscan stop     - Stop the scanner manually                        --
--   /gsautoscan status   - Show current scan progress                       --
-------------------------------------------------------------------------------

local SCAN_INTERVAL   = 30   -- seconds between each full scan pass
local MEMBER_DELAY    = 1.5  -- seconds between individual member inspect calls
                             -- (keeps us within inspect throttle limits)
local RECORD_MAX_AGE  = 500  -- 5 hours in GearScore timestamp units (5 * 100)

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------
local GS_AutoScan = {
    active          = false,  -- is the scanner running?
    memberQueue     = {},     -- members still needing a scan this pass
    passTimer       = 0,      -- counts up to SCAN_INTERVAL between passes
    memberTimer     = 0,      -- counts up to MEMBER_DELAY between member scans
    currentMember   = nil,    -- unit token being inspected right now
    passCount       = 0,      -- how many full passes have completed
    totalScanned    = 0,      -- cumulative unique members scanned this session
    startGroupNames = {},     -- snapshot of group names when scanner started
}

-------------------------------------------------------------------------------
-- Helper: returns true if a player record exists and is less than 5 hours old
-------------------------------------------------------------------------------
local function GS_AutoScan_IsRecordFresh(record)
    if not record or not record.Date then return false end
    local currentTime = GearScore_GetTimeStamp()
    if not currentTime then return false end  -- CalendarGetDate() not ready yet
    local age = currentTime - record.Date
    return age < RECORD_MAX_AGE
end

-------------------------------------------------------------------------------
-- Helper: build a list of party/raid unit tokens including the local player
-------------------------------------------------------------------------------
local function GS_AutoScan_GetGroupUnits()
    local units = {}
    local numRaid  = GetNumRaidMembers()
    local numParty = GetNumPartyMembers()

    if numRaid > 0 then
        -- In a raid: raid1..raid40 (includes the player's own slot)
        for i = 1, 40 do
            local name = UnitName("raid"..i)
            if name and name ~= "UNKNOWN" then
                tinsert(units, "raid"..i)
            end
        end
    elseif numParty > 0 then
        -- In a party: party1..party4 (player token not included, add explicitly)
        for i = 1, 4 do
            local name = UnitName("party"..i)
            if name and name ~= "UNKNOWN" then
                tinsert(units, "party"..i)
            end
        end
        tinsert(units, "player")
    end
    return units
end

-------------------------------------------------------------------------------
-- Helper: check if all current group members have a fresh record (< 5 hours)
-- Player token is skipped as we cannot inspect ourselves
-------------------------------------------------------------------------------
local function GS_AutoScan_AllScanned()
    local units = GS_AutoScan_GetGroupUnits()
    if #units == 0 then return true end

    local realm = GetRealmName()
    for _, token in ipairs(units) do
        local name = UnitName(token)
        if name and token ~= "player" and not GS_AutoScan_IsRecordFresh(GS_Data[realm].Players[name]) then
            return false
        end
    end
    return true
end

-------------------------------------------------------------------------------
-- Print average GearScore and iLvl for the full group including the player
-------------------------------------------------------------------------------
local function GS_AutoScan_PrintGroupAverage()
    local realm = GetRealmName()
    local units = GS_AutoScan_GetGroupUnits()

    local totalGS, totalIlvl, count = 0, 0, 0
    for _, token in ipairs(units) do
        local name = UnitName(token)
        if name and GS_Data[realm].Players[name] then
            local record = GS_Data[realm].Players[name]
            totalGS   = totalGS   + (record.GearScore or 0)
            totalIlvl = totalIlvl + (record.Average   or 0)
            count = count + 1
        end
    end

    if count == 0 then return end

    local avgGS   = math.floor(totalGS   / count)
    local avgIlvl = math.floor(totalIlvl / count)

    local Red, Green, Blue = GearScore_GetQuality(avgGS)
    local colorHex = string.format("|cff%02x%02x%02x", Red*255, Blue*255, Green*255)

    print("|cff00ff00[GearScore AutoScan]|r Group scan complete ("..count.." members) "..
          "-- Avg GS: "..colorHex..avgGS.."|r  Avg iLvl: |cffffff00"..avgIlvl.."|r")
end

-------------------------------------------------------------------------------
-- Kick off a new scan pass: populate the queue with members needing a scan
-- Skips player token (cannot inspect self) and UNKNOWN names
-------------------------------------------------------------------------------
local function GS_AutoScan_StartPass()
    local units = GS_AutoScan_GetGroupUnits()
    local realm = GetRealmName()

    GS_AutoScan.memberQueue = {}
    for _, token in ipairs(units) do
        local name = UnitName(token)
        if name and name ~= "UNKNOWN" and token ~= "player" then
            local record = GS_Data[realm].Players[name]
            if not GS_AutoScan_IsRecordFresh(record) then
                tinsert(GS_AutoScan.memberQueue, token)
            end
        end
    end
end

-------------------------------------------------------------------------------
-- Scan the next member in the queue
-------------------------------------------------------------------------------
local function GS_AutoScan_ScanNext()
    local token = tremove(GS_AutoScan.memberQueue, 1)
    if not token then return end

    local name = UnitName(token)
    if not name or name == "UNKNOWN" then return end

    -- Don't interfere with a manual inspect the player has open
    if ( InspectFrame and InspectFrame:IsShown() ) or ( Examiner and Examiner:IsShown() ) then
        return
    end

    -- Only inspect if we actually can (range / visible check)
    if not CanInspect(token) then
        return
    end

    GS_AutoScan.currentMember = token

    NotifyInspect(token)
    local gs, ilvl = GearScore_GetScore(name, token, 1)  -- saveToDatabase = 1

    local realm = GetRealmName()
    if GS_Data[realm].Players[name] then
        GS_AutoScan.totalScanned = GS_AutoScan.totalScanned + 1
        GearScore_Send(name, "ALL")
    end
end

-------------------------------------------------------------------------------
-- OnUpdate handler (runs every frame, gated by timers)
-------------------------------------------------------------------------------
local function GS_AutoScan_OnUpdate(self, elapsed)
    if not GS_AutoScan.active then return end
    if GS_PlayerIsInCombat then return end  -- pause during combat

    if not GS_Data or not GS_Data[GetRealmName()] then return end

    -- No group? Reset state and stop
    if GetNumRaidMembers() == 0 and GetNumPartyMembers() == 0 then
        GS_AutoScan.active          = false
        GS_AutoScan.memberQueue     = {}
        GS_AutoScan.passTimer       = 0
        GS_AutoScan.memberTimer     = 0
        GS_AutoScan.passCount       = 0
        GS_AutoScan.totalScanned    = 0
        GS_AutoScan.startGroupNames = {}
        self:Hide()
        return
    end

    -------------------------------------------------------------------
    -- Member-level tick: send one inspect per MEMBER_DELAY seconds
    -------------------------------------------------------------------
    if #GS_AutoScan.memberQueue > 0 then
        GS_AutoScan.memberTimer = GS_AutoScan.memberTimer + elapsed
        if GS_AutoScan.memberTimer >= MEMBER_DELAY then
            GS_AutoScan.memberTimer = 0
            GS_AutoScan_ScanNext()
        end
        return  -- don't advance the pass timer while we still have members queued
    end

    -------------------------------------------------------------------
    -- Pass-level tick: wait SCAN_INTERVAL before the next pass
    -------------------------------------------------------------------
    GS_AutoScan.passTimer = GS_AutoScan.passTimer + elapsed
    if GS_AutoScan.passTimer >= SCAN_INTERVAL then
        GS_AutoScan.passTimer = 0
        GS_AutoScan.passCount = GS_AutoScan.passCount + 1

        GS_AutoScan_StartPass()
        GS_AutoScan.memberTimer = 0

        -- Queue is empty meaning everyone is already fresh
        -- Only print if we actually scanned someone this session
        if #GS_AutoScan.memberQueue == 0 then
            if GS_AutoScan.totalScanned > 0 then
                GS_AutoScan_PrintGroupAverage()
            end
            GS_AutoScan.active = false
            self:Hide()
            return
        end
    end
end

-------------------------------------------------------------------------------
-- Create the timer frame
-------------------------------------------------------------------------------
local GS_AutoScanFrame = CreateFrame("Frame", "GS_AutoScanFrame", UIParent)
GS_AutoScanFrame:SetScript("OnUpdate", GS_AutoScan_OnUpdate)
GS_AutoScanFrame:Hide()

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

-- Start the scanner
function GearScore_AutoScan_Start()
    if GS_AutoScan.active then
        return
    end

    if GetNumRaidMembers() == 0 and GetNumPartyMembers() == 0 then
        print("|cff00ff00[GearScore AutoScan]|r You are not in a party or raid.")
        return
    end

    GS_AutoScan.active       = true
    GS_AutoScan.passCount    = 0
    GS_AutoScan.totalScanned = 0
    GS_AutoScan.passTimer    = SCAN_INTERVAL  -- trigger immediately on first frame
    GS_AutoScan.memberTimer  = 0
    GS_AutoScan.memberQueue  = {}

    -- Snapshot current group names so we can detect roster changes later
    GS_AutoScan.startGroupNames = {}
    for _, token in ipairs(GS_AutoScan_GetGroupUnits()) do
        local name = UnitName(token)
        if name and name ~= "UNKNOWN" then
            GS_AutoScan.startGroupNames[name] = true
        end
    end

    GS_AutoScanFrame:Show()
end

-- Stop the scanner
function GearScore_AutoScan_Stop()
    if not GS_AutoScan.active then
        print("|cff00ff00[GearScore AutoScan]|r Scanner is not running.")
        return
    end
    GS_AutoScan.active = false
    GS_AutoScanFrame:Hide()
    print("|cff00ff00[GearScore AutoScan]|r Stopped. ("..GS_AutoScan.totalScanned.." member(s) scanned this session)")
end

-- Status
function GearScore_AutoScan_Status()
    if not GS_AutoScan.active then
        print("|cff00ff00[GearScore AutoScan]|r Status: |cffff4444Stopped|r")
        return
    end
    local queued = #GS_AutoScan.memberQueue
    local nextPass = math.max(0, math.floor(SCAN_INTERVAL - GS_AutoScan.passTimer))
    print("|cff00ff00[GearScore AutoScan]|r Status: |cff44ff44Running|r  |  "..
          "Pass: "..GS_AutoScan.passCount.."  |  "..
          "Queue: "..queued.." member(s)  |  "..
          "Next pass in: "..nextPass.."s  |  "..
          "Scanned this session: "..GS_AutoScan.totalScanned)
end

-------------------------------------------------------------------------------
-- Auto-start: begin scanning when player joins a group
-------------------------------------------------------------------------------
local GS_AutoScanEventFrame = CreateFrame("Frame")
GS_AutoScanEventFrame:RegisterEvent("PARTY_MEMBERS_CHANGED")
GS_AutoScanEventFrame:RegisterEvent("RAID_ROSTER_UPDATE")
GS_AutoScanEventFrame:SetScript("OnEvent", function(self, event)
    C_Timer_Frame = C_Timer_Frame or CreateFrame("Frame")
    local delay = 2  -- seconds to wait before kicking off scan
    local elapsed = 0
    C_Timer_Frame:SetScript("OnUpdate", function(f, e)
        elapsed = elapsed + e
        if elapsed >= delay then
            f:SetScript("OnUpdate", nil)
            if not GS_AutoScan.active then
                local numRaid  = GetNumRaidMembers()
                local numParty = GetNumPartyMembers()
                if numRaid > 0 or numParty > 0 then
                    GearScore_AutoScan_Start()
                end
            end
        end
    end)
end)

-------------------------------------------------------------------------------
-- Slash command:  /gsautoscan [stop|status]
-------------------------------------------------------------------------------
SlashCmdList["GSAUTOSCAN"] = function(cmd)
    local arg = strtrim(strlower(cmd or ""))
    if arg == "stop" then
        GearScore_AutoScan_Stop()
    elseif arg == "status" then
        GearScore_AutoScan_Status()
    else
        GearScore_AutoScan_Start()
    end
end
SLASH_GSAUTOSCAN1 = "/gsautoscan"
