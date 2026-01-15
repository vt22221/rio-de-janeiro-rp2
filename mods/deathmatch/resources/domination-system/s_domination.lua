mysql = exports.mysql
factions = exports.factions
integration = exports.integration
logs = exports.logs

local resourceName = getResourceName(getThisResource())
local moduleObjects = {}
local factionModules = {}
local factionStock = {}
local researchTimers = {}
local activeWars = {}
local warTimers = {}
local zoneShapes = {}
local siegeZones = {}
local activeRoutes = {}
local commandCooldowns = {}
local convoyState = {}
local airdropState = {}

local function nowTimestamp()
    return getRealTime().timestamp
end

local function formatResourceList(resources)
    local parts = {}
    for _, key in ipairs(RESOURCE_TYPES) do
        if resources[key] and resources[key] > 0 then
            table.insert(parts, string.format("%s: %d", key, resources[key]))
        end
    end
    return table.concat(parts, ", ")
end

local function getPrimaryFactionId(player)
    local factionData = getElementData(player, "faction") or {}
    local selectedId
    local selectedCount = math.huge
    for factionId, data in pairs(factionData) do
        if data.count and data.count < selectedCount then
            selectedId = factionId
            selectedCount = data.count
        elseif not data.count and not selectedId then
            selectedId = factionId
        end
    end
    return tonumber(selectedId)
end

local function isFactionLeader(player, factionId)
    return factions:isPlayerFactionLeader(player, factionId)
end

local function isCommandOnCooldown(player, command)
    local cooldown = COMMAND_COOLDOWNS[command]
    if not cooldown then
        return false
    end
    local now = nowTimestamp()
    commandCooldowns[player] = commandCooldowns[player] or {}
    if commandCooldowns[player][command] and now < commandCooldowns[player][command] then
        return true
    end
    commandCooldowns[player][command] = now + cooldown
    return false
end

local function ensureFactionStock(factionId)
    factionId = tonumber(factionId)
    if not factionId then
        return nil
    end
    if factionStock[factionId] then
        return factionStock[factionId]
    end
    local qh = dbQuery(mysql:getConn("mta"), "SELECT * FROM domination_faction_stock WHERE faction_id = ?", factionId)
    local result = dbPoll(qh, 10000)
    if result and result[1] then
        factionStock[factionId] = {
            oil = tonumber(result[1].oil) or 0,
            steel = tonumber(result[1].steel) or 0,
            components = tonumber(result[1].components) or 0,
            elite_components = tonumber(result[1].elite_components) or 0,
            control_points = tonumber(result[1].control_points) or 0,
        }
    else
        factionStock[factionId] = { oil = 0, steel = 0, components = 0, elite_components = 0, control_points = 0 }
        dbExec(mysql:getConn("mta"), "INSERT INTO domination_faction_stock (faction_id, oil, steel, components, elite_components, control_points) VALUES (?, 0, 0, 0, 0, 0)", factionId)
    end
    return factionStock[factionId]
end

local function updateFactionStock(factionId)
    local stock = ensureFactionStock(factionId)
    if not stock then
        return
    end
    dbExec(mysql:getConn("mta"), "UPDATE domination_faction_stock SET oil=?, steel=?, components=?, elite_components=?, control_points=? WHERE faction_id=?", stock.oil, stock.steel, stock.components, stock.elite_components, stock.control_points, factionId)
end

local function adjustFactionStock(factionId, delta)
    local stock = ensureFactionStock(factionId)
    if not stock then
        return false
    end
    for _, key in ipairs(RESOURCE_TYPES) do
        stock[key] = math.max(0, (stock[key] or 0) + (delta[key] or 0))
    end
    updateFactionStock(factionId)
    return true
end

local function hasFactionResources(factionId, cost)
    local stock = ensureFactionStock(factionId)
    if not stock then
        return false
    end
    for _, key in ipairs(RESOURCE_TYPES) do
        if (cost[key] or 0) > (stock[key] or 0) then
            return false
        end
    end
    return true
end

local function consumeFactionResources(factionId, cost)
    if not hasFactionResources(factionId, cost) then
        return false
    end
    local stock = ensureFactionStock(factionId)
    for _, key in ipairs(RESOURCE_TYPES) do
        stock[key] = math.max(0, (stock[key] or 0) - (cost[key] or 0))
    end
    updateFactionStock(factionId)
    return true
end

local function getFactionTechs(factionId)
    local techs = {}
    local qh = dbQuery(mysql:getConn("mta"), "SELECT tech_id FROM domination_faction_techs WHERE faction_id = ?", factionId)
    local result = dbPoll(qh, 10000)
    if result then
        for _, row in ipairs(result) do
            techs[row.tech_id] = true
        end
    end
    return techs
end

local function hasFactionTech(factionId, techId)
    if not techId then
        return true
    end
    local techs = getFactionTechs(factionId)
    return techs[techId] or false
end

local function buildSiegeZone(moduleElement)
    local moduleType = getElementData(moduleElement, "domination:moduleType")
    if moduleType ~= "command" then
        return
    end
    local x, y, z = getElementPosition(moduleElement)
    local shape = createColSphere(x, y, z, 90)
    setElementData(shape, "domination:siege", true, false)
    siegeZones[moduleElement] = shape
end

local function removeSiegeZone(moduleElement)
    local shape = siegeZones[moduleElement]
    if shape and isElement(shape) then
        destroyElement(shape)
    end
    siegeZones[moduleElement] = nil
end

local function createModule(factionId, moduleType, x, y, z, interior, dimension, health)
    local definition = MODULE_DEFINITIONS[moduleType]
    if not definition then
        return false
    end
    local object = createObject(definition.model, x, y, z)
    if not object then
        return false
    end
    setElementInterior(object, interior or 0)
    setElementDimension(object, dimension or 0)
    setElementData(object, "domination:moduleType", moduleType, false)
    setElementData(object, "domination:factionId", factionId, false)
    setElementData(object, "domination:health", health or definition.health, false)
    setElementFrozen(object, true)
    setObjectBreakable(object, true)

    if not moduleObjects[object] then
        moduleObjects[object] = true
    end

    factionModules[factionId] = factionModules[factionId] or {}
    table.insert(factionModules[factionId], object)

    buildSiegeZone(object)

    return object
end

addEventHandler("onObjectBreak", root, function(attacker)
    if getElementData(source, "domination:moduleId") then
        cancelEvent()
    end
end)

local function insertModuleRecord(factionId, moduleType, x, y, z, interior, dimension, health)
    dbExec(mysql:getConn("mta"), "INSERT INTO domination_faction_modules (faction_id, module_type, x, y, z, interior, dimension, health, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, NOW(), NOW())", factionId, moduleType, x, y, z, interior, dimension, health)
    local qh = dbQuery(mysql:getConn("mta"), "SELECT LAST_INSERT_ID() AS id")
    local result = dbPoll(qh, 10000)
    return result and result[1] and tonumber(result[1].id)
end

local function loadModules()
    local qh = dbQuery(mysql:getConn("mta"), "SELECT * FROM domination_faction_modules")
    local result = dbPoll(qh, 10000)
    if not result then
        return
    end
    for _, row in ipairs(result) do
        local factionId = tonumber(row.faction_id)
        local moduleType = row.module_type
        local object = createModule(factionId, moduleType, tonumber(row.x), tonumber(row.y), tonumber(row.z), tonumber(row.interior), tonumber(row.dimension), tonumber(row.health))
        if object then
            setElementData(object, "domination:moduleId", tonumber(row.id), false)
        end
    end
end

local function getFactionModuleCount(factionId, moduleType)
    local count = 0
    local modules = factionModules[factionId] or {}
    for _, object in ipairs(modules) do
        if isElement(object) and getElementData(object, "domination:moduleType") == moduleType then
            count = count + 1
        end
    end
    return count
end

local function removeModuleObject(object)
    if not isElement(object) then
        return
    end
    removeSiegeZone(object)
    moduleObjects[object] = nil
    local factionId = getElementData(object, "domination:factionId")
    if factionId and factionModules[factionId] then
        for index, entry in ipairs(factionModules[factionId]) do
            if entry == object then
                table.remove(factionModules[factionId], index)
                break
            end
        end
    end
    destroyElement(object)
end

local function pauseFactionResearch(factionId, reason)
    local qh = dbQuery(mysql:getConn("mta"), "SELECT * FROM domination_faction_research WHERE faction_id = ? AND status = 'active'", factionId)
    local result = dbPoll(qh, 10000)
    if not result or not result[1] then
        return
    end
    local row = result[1]
    local remaining = tonumber(row.remaining_seconds) or 0
    local endTime = tonumber(row.ends_at_ts) or 0
    local now = nowTimestamp()
    if endTime > now then
        remaining = endTime - now
    end
    dbExec(mysql:getConn("mta"), "UPDATE domination_faction_research SET status='paused', remaining_seconds=?, updated_at=NOW(), ends_at=NULL, ends_at_ts=NULL WHERE faction_id=?", remaining, factionId)
    if researchTimers[factionId] then
        killTimer(researchTimers[factionId])
        researchTimers[factionId] = nil
    end
    exports.factions:sendNotiToAllFactionMembers(factionId, "Pesquisa Interrompida", reason or "Centro de pesquisa destruído", true)
end

local function resumeFactionResearch(factionId)
    local qh = dbQuery(mysql:getConn("mta"), "SELECT * FROM domination_faction_research WHERE faction_id = ? AND status = 'paused'", factionId)
    local result = dbPoll(qh, 10000)
    if not result or not result[1] then
        return
    end
    local row = result[1]
    local remaining = tonumber(row.remaining_seconds) or 0
    if remaining <= 0 then
        return
    end
    local endTimestamp = nowTimestamp() + remaining
    dbExec(mysql:getConn("mta"), "UPDATE domination_faction_research SET status='active', ends_at=FROM_UNIXTIME(?), ends_at_ts=?, updated_at=NOW() WHERE faction_id=?", endTimestamp, endTimestamp, factionId)
    researchTimers[factionId] = setTimer(function()
        triggerEvent("domination:researchComplete", resourceRoot, factionId, row.tech_id)
    end, remaining * 1000, 1)
    exports.factions:sendNotiToAllFactionMembers(factionId, "Pesquisa Retomada", "Centro de pesquisa restaurado", true)
end

local function addFactionTech(factionId, techId)
    dbExec(mysql:getConn("mta"), "INSERT IGNORE INTO domination_faction_techs (faction_id, tech_id, completed_at) VALUES (?, ?, NOW())", factionId, techId)
end

local function handleResearchComplete(factionId, techId)
    dbExec(mysql:getConn("mta"), "UPDATE domination_faction_research SET status='completed', updated_at=NOW(), ends_at=NOW(), ends_at_ts=? WHERE faction_id=?", nowTimestamp(), factionId)
    addFactionTech(factionId, techId)
    exports.factions:sendNotiToAllFactionMembers(factionId, "Pesquisa Concluída", "A tecnologia '" .. TECH_DEFINITIONS[techId].name .. "' foi concluída.", false)
    logs:dbLog(nil, 4, nil, "Domination research completed: faction " .. factionId .. " tech " .. techId)
end

addEvent("domination:researchComplete", true)
addEventHandler("domination:researchComplete", resourceRoot, function(factionId, techId)
    if researchTimers[factionId] then
        killTimer(researchTimers[factionId])
        researchTimers[factionId] = nil
    end
    handleResearchComplete(factionId, techId)
end)

local function loadResearch()
    local qh = dbQuery(mysql:getConn("mta"), "SELECT *, UNIX_TIMESTAMP(ends_at) AS ends_at_ts FROM domination_faction_research WHERE status IN ('active','paused')")
    local result = dbPoll(qh, 10000)
    if not result then
        return
    end
    for _, row in ipairs(result) do
        local factionId = tonumber(row.faction_id)
        local techId = row.tech_id
        if row.status == "active" then
            local endTimestamp = tonumber(row.ends_at_ts) or 0
            local remaining = endTimestamp - nowTimestamp()
            if remaining <= 0 then
                handleResearchComplete(factionId, techId)
            else
                researchTimers[factionId] = setTimer(function()
                    triggerEvent("domination:researchComplete", resourceRoot, factionId, techId)
                end, remaining * 1000, 1)
            end
        end
    end
end

local function scheduleWarTimers(warId, factionA, factionB, startTimestamp, endTimestamp)
    local startDelay = math.max(0, startTimestamp - nowTimestamp())
    local endDelay = math.max(0, endTimestamp - nowTimestamp())
    warTimers[warId] = {}
    warTimers[warId].start = setTimer(function()
        activeWars[warId].status = "active"
        dbExec(mysql:getConn("mta"), "UPDATE domination_wars SET status='active' WHERE id=?", warId)
        outputChatBox("[Dominação] Guerra iniciada entre as facções " .. factionA .. " e " .. factionB .. "!", root, 255, 90, 60)
    end, startDelay * 1000, 1)

    warTimers[warId].finish = setTimer(function()
        if activeWars[warId] and activeWars[warId].status == "active" then
            activeWars[warId].status = "ended"
            dbExec(mysql:getConn("mta"), "UPDATE domination_wars SET status='ended' WHERE id=?", warId)
            outputChatBox("[Dominação] A janela de guerra entre as facções " .. factionA .. " e " .. factionB .. " terminou sem vitória.", root, 255, 120, 90)
        end
    end, endDelay * 1000, 1)
end

local function loadWars()
    local qh = dbQuery(mysql:getConn("mta"), "SELECT *, UNIX_TIMESTAMP(start_time) AS start_ts, UNIX_TIMESTAMP(end_time) AS end_ts FROM domination_wars WHERE status IN ('scheduled','active')")
    local result = dbPoll(qh, 10000)
    if not result then
        return
    end
    for _, row in ipairs(result) do
        local warId = tonumber(row.id)
        activeWars[warId] = {
            attacker = tonumber(row.attacker_id),
            defender = tonumber(row.defender_id),
            status = row.status,
            start_ts = tonumber(row.start_ts),
            end_ts = tonumber(row.end_ts),
        }
        scheduleWarTimers(warId, row.attacker_id, row.defender_id, tonumber(row.start_ts), tonumber(row.end_ts))
    end
end

local function isWarActiveBetween(factionA, factionB)
    for _, war in pairs(activeWars) do
        if war.status == "active" then
            if (war.attacker == factionA and war.defender == factionB) or (war.attacker == factionB and war.defender == factionA) then
                return true
            end
        end
    end
    return false
end

local function getZoneTypeForElement(element)
    for _, zone in ipairs(zoneShapes) do
        if isElementWithinColShape(element, zone.shape) then
            return zone.type
        end
    end
    return "neutral"
end

local function isInSiegeZone(element)
    for moduleElement, shape in pairs(siegeZones) do
        if isElement(shape) and isElementWithinColShape(element, shape) then
            return true
        end
    end
    return false
end

local function setupZones()
    for _, zone in ipairs(ZONE_DEFINITIONS) do
        local shape = createColSphere(zone.x, zone.y, zone.z, zone.radius)
        setElementData(shape, "domination:zoneType", zone.type, false)
        table.insert(zoneShapes, { shape = shape, type = zone.type, name = zone.name })
    end
end

local function startConvoy()
    if convoyState.active then
        return
    end
    local zone = ZONE_DEFINITIONS[4]
    if not zone then
        return
    end
    local vehicle = createVehicle(433, zone.x + 10, zone.y + 10, zone.z)
    if not vehicle then
        return
    end
    local ped = createPed(287, zone.x + 12, zone.y + 12, zone.z)
    warpPedIntoVehicle(ped, vehicle)
    setVehicleLocked(vehicle, true)

    local marker = createMarker(zone.x + 10, zone.y + 10, zone.z + 1, "cylinder", 3, 255, 180, 60, 160)
    attachElements(marker, vehicle, 0, -4, 0)

    convoyState = { active = true, vehicle = vehicle, marker = marker, ped = ped }
    outputChatBox("[Dominação] Comboio de componentes raros entrou em Terra de Ninguém!", root, 255, 160, 60)

    addEventHandler("onMarkerHit", marker, function(player, matchingDimension)
        if not matchingDimension or getElementType(player) ~= "player" then
            return
        end
        local factionId = getPrimaryFactionId(player)
        if not factionId then
            outputChatBox("[Dominação] Você precisa estar em uma facção para saquear o comboio.", player, 255, 100, 80)
            return
        end
        adjustFactionStock(factionId, EVENT_SETTINGS.convoyReward)
        outputChatBox("[Dominação] Seu grupo capturou o comboio e recebeu recursos raros.", player, 90, 220, 90)
        exports.factions:sendNotiToAllFactionMembers(factionId, "Comboio Capturado", "Recursos raros foram adicionados ao estoque.", false)
        logs:dbLog(player, 4, player, "Domination convoy captured by faction " .. factionId)
        if isElement(marker) then destroyElement(marker) end
        if isElement(ped) then destroyElement(ped) end
        if isElement(vehicle) then destroyElement(vehicle) end
        convoyState = {}
    end)

    setTimer(function()
        if convoyState.active and isElement(vehicle) then
            destroyElement(vehicle)
        end
        if convoyState.marker and isElement(convoyState.marker) then
            destroyElement(convoyState.marker)
        end
        if convoyState.ped and isElement(convoyState.ped) then
            destroyElement(convoyState.ped)
        end
        convoyState = {}
    end, 1800000, 1)
end

local function startAirdrop()
    if airdropState.active then
        return
    end
    local zone = ZONE_DEFINITIONS[4]
    if not zone then
        return
    end
    local angle = math.random() * math.pi * 2
    local radius = math.random(50, zone.radius - 20)
    local x = zone.x + math.cos(angle) * radius
    local y = zone.y + math.sin(angle) * radius
    local z = zone.z + 5

    local crate = createObject(1271, x, y, z)
    local marker = createMarker(x, y, z - 1, "cylinder", 3, 120, 200, 255, 160)
    airdropState = { active = true, crate = crate, marker = marker }

    outputChatBox("[Dominação] Airdrop detectado em Terra de Ninguém!", root, 120, 200, 255)

    addEventHandler("onMarkerHit", marker, function(player, matchingDimension)
        if not matchingDimension or getElementType(player) ~= "player" then
            return
        end
        local factionId = getPrimaryFactionId(player)
        if not factionId then
            outputChatBox("[Dominação] Você precisa estar em uma facção para coletar o airdrop.", player, 255, 100, 80)
            return
        end
        adjustFactionStock(factionId, EVENT_SETTINGS.airdropReward)
        outputChatBox("[Dominação] Airdrop saqueado. Recursos enviados ao depósito da facção.", player, 90, 220, 90)
        exports.factions:sendNotiToAllFactionMembers(factionId, "Airdrop Capturado", "Recursos adicionados ao estoque.", false)
        logs:dbLog(player, 4, player, "Domination airdrop captured by faction " .. factionId)
        if isElement(marker) then destroyElement(marker) end
        if isElement(crate) then destroyElement(crate) end
        airdropState = {}
    end)

    setTimer(function()
        if airdropState.marker and isElement(airdropState.marker) then
            destroyElement(airdropState.marker)
        end
        if airdropState.crate and isElement(airdropState.crate) then
            destroyElement(airdropState.crate)
        end
        airdropState = {}
    end, 1800000, 1)
end

local function setupEventTimers()
    setTimer(startConvoy, EVENT_SETTINGS.convoyInterval * 1000, 0)
    setTimer(startAirdrop, EVENT_SETTINGS.airdropInterval * 1000, 0)
end

local function updateResearchBoost(player)
    local hasPerk, value = exports.donators:hasPlayerPerk(player, RESEARCH_BOOST_PERK_ID)
    local count = tonumber(value) or 0
    if not hasPerk or count <= 0 then
        return false
    end
    exports.donators:updatePerkValue(player, RESEARCH_BOOST_PERK_ID, tostring(count - 1))
    return true
end

local function getPerkCount(player, perkId)
    local hasPerk, value = exports.donators:hasPlayerPerk(player, perkId)
    if not hasPerk then
        return 0
    end
    return tonumber(value) or 0
end

local function setPerkCount(player, perkId, count)
    exports.donators:updatePerkValue(player, perkId, tostring(math.max(0, count)))
end

local function applyLogisticsContract(player)
    local count = getPerkCount(player, LOGISTICS_CONTRACT_PERK_ID)
    if count <= 0 then
        return false
    end
    setPerkCount(player, LOGISTICS_CONTRACT_PERK_ID, count - 1)
    return true
end

local function applyRepairKit(player)
    local count = getPerkCount(player, REPAIR_KIT_PERK_ID)
    if count <= 0 then
        return false
    end
    setPerkCount(player, REPAIR_KIT_PERK_ID, count - 1)
    return true
end

local function countFactionModulesByType(factionId, moduleType)
    local count = 0
    for _, object in ipairs(factionModules[factionId] or {}) do
        if isElement(object) and getElementData(object, "domination:moduleType") == moduleType then
            count = count + 1
        end
    end
    return count
end

local function canAttackModule(attackerFaction, defenderFaction)
    return attackerFaction and defenderFaction and isWarActiveBetween(attackerFaction, defenderFaction)
end

addEventHandler("onElementDamage", root, function(attacker, weapon, bodypart, loss)
    if getElementType(source) ~= "object" or not getElementData(source, "domination:moduleId") then
        return
    end
    local moduleFaction = getElementData(source, "domination:factionId")
    local attackerPlayer = attacker
    if attacker and getElementType(attacker) == "vehicle" then
        attackerPlayer = getVehicleController(attacker)
    end
    local attackerFaction = attackerPlayer and getPrimaryFactionId(attackerPlayer) or nil
    if not attackerFaction or not canAttackModule(attackerFaction, moduleFaction) then
        cancelEvent()
        return
    end

    local currentHealth = getElementData(source, "domination:health") or 0
    local damage = tonumber(loss) or 50
    local newHealth = currentHealth - damage
    setElementData(source, "domination:health", newHealth, false)
    if newHealth > 0 then
        dbExec(mysql:getConn("mta"), "UPDATE domination_faction_modules SET health=?, updated_at=NOW() WHERE id=?", newHealth, getElementData(source, "domination:moduleId"))
        return
    end

    local moduleType = getElementData(source, "domination:moduleType")
    local moduleId = getElementData(source, "domination:moduleId")
    removeModuleObject(source)
    dbExec(mysql:getConn("mta"), "DELETE FROM domination_faction_modules WHERE id=?", moduleId)
    exports.factions:sendNotiToAllFactionMembers(moduleFaction, "Módulo destruído", "Seu módulo de " .. MODULE_DEFINITIONS[moduleType].name .. " foi destruído.", true)
    logs:dbLog(attackerPlayer, 4, attackerPlayer, "Domination module destroyed: faction " .. moduleFaction .. " type " .. moduleType)

    if moduleType == "research" then
        pauseFactionResearch(moduleFaction, "Centro de pesquisa destruído")
    end

    if moduleType == "command" and attackerFaction then
        for warId, war in pairs(activeWars) do
            if war.status == "active" and ((war.attacker == attackerFaction and war.defender == moduleFaction) or (war.attacker == moduleFaction and war.defender == attackerFaction)) then
                war.status = "ended"
                war.winner = attackerFaction
                dbExec(mysql:getConn("mta"), "UPDATE domination_wars SET status='ended', winner_id=? WHERE id=?", attackerFaction, warId)
                local reward = { oil = 30, steel = 30, components = 30, elite_components = 10 }
                adjustFactionStock(attackerFaction, reward)
                local attackerStock = ensureFactionStock(attackerFaction)
                local defenderStock = ensureFactionStock(moduleFaction)
                attackerStock.control_points = (attackerStock.control_points or 0) + 1
                defenderStock.control_points = math.max(0, (defenderStock.control_points or 0) - 1)
                updateFactionStock(attackerFaction)
                updateFactionStock(moduleFaction)
                outputChatBox("[Dominação] O Centro de Comando da facção " .. moduleFaction .. " foi destruído. Vitória da facção " .. attackerFaction .. "!", root, 255, 80, 80)
                exports.factions:sendNotiToAllFactionMembers(attackerFaction, "Vitória", "Centro de comando inimigo destruído. Controle transferido.", false)
                exports.factions:sendNotiToAllFactionMembers(moduleFaction, "Derrota", "Seu Centro de Comando foi destruído durante a janela de guerra.", true)
                logs:dbLog(attackerPlayer, 4, attackerPlayer, "Domination war victory: attacker " .. attackerFaction .. " defender " .. moduleFaction)
                break
            end
        end
    end
end)

addEventHandler("onPlayerDamage", root, function(attacker)
    if not attacker or getElementType(attacker) ~= "player" then
        return
    end
    local victimFaction = getPrimaryFactionId(source)
    local attackerFaction = getPrimaryFactionId(attacker)
    if not victimFaction or not attackerFaction then
        return
    end
    if victimFaction == attackerFaction then
        return
    end
    local zoneType = getZoneTypeForElement(source)
    if zoneType ~= "resource" and zoneType ~= "no_mans_land" and not isInSiegeZone(source) then
        cancelEvent()
        return
    end
    if not isWarActiveBetween(victimFaction, attackerFaction) then
        cancelEvent()
    end
end)

addEventHandler("onVehicleStartEnter", root, function(player, seat)
    if seat ~= 0 or getElementType(player) ~= "player" then
        return
    end
    local factionId = getPrimaryFactionId(player)
    if not factionId then
        return
    end
    local vehicleFaction = getElementData(source, "faction")
    if tonumber(vehicleFaction or -1) ~= factionId then
        return
    end
    local model = getElementModel(source)
    local cost = ASSET_OPERATION_COSTS[model]
    if not cost then
        return
    end
    if not hasFactionTech(factionId, "aerial") and model == 520 then
        outputChatBox("[Dominação] Este jato requer o Programa Aéreo de facção.", player, 255, 120, 80)
        cancelEvent()
        return
    end
    if not hasFactionResources(factionId, cost) then
        outputChatBox("[Dominação] Estoque insuficiente para operar este ativo de guerra.", player, 255, 100, 80)
        cancelEvent()
        return
    end
    consumeFactionResources(factionId, cost)
    local vehicle = source
    if isTimer(getElementData(vehicle, "domination:drainTimer")) then
        killTimer(getElementData(vehicle, "domination:drainTimer"))
    end
    local drainTimer = setTimer(function()
        if not isElement(vehicle) then
            return
        end
        local driver = getVehicleController(vehicle)
        if not driver then
            killTimer(getElementData(vehicle, "domination:drainTimer"))
            setElementData(vehicle, "domination:drainTimer", nil, false)
            return
        end
        if hasFactionResources(factionId, cost) then
            consumeFactionResources(factionId, cost)
        else
            setVehicleEngineState(vehicle, false)
            outputChatBox("[Dominação] Seu ativo parou por falta de recursos no depósito.", driver, 255, 100, 80)
        end
    end, 60000, 0)
    setElementData(vehicle, "domination:drainTimer", drainTimer, false)
end)

addCommandHandler("factionbuild", function(player, command, moduleType)
    if not moduleType or moduleType == "" then
        outputChatBox("Uso: /factionbuild <" .. table.concat((function()
            local keys = {}
            for key in pairs(MODULE_DEFINITIONS) do
                table.insert(keys, key)
            end
            return keys
        end)(), "|") .. ">", player, 255, 200, 120)
        return
    end
    if isCommandOnCooldown(player, command) then
        outputChatBox("[Dominação] Aguarde antes de repetir o comando.", player, 255, 160, 120)
        return
    end
    local factionId = getPrimaryFactionId(player)
    if not factionId then
        outputChatBox("[Dominação] Você precisa estar em uma facção.", player, 255, 120, 80)
        return
    end
    if not isFactionLeader(player, factionId) then
        outputChatBox("[Dominação] Apenas líderes de facção podem construir módulos.", player, 255, 120, 80)
        return
    end
    moduleType = string.lower(moduleType)
    local definition = MODULE_DEFINITIONS[moduleType]
    if not definition then
        outputChatBox("[Dominação] Tipo de módulo inválido.", player, 255, 120, 80)
        return
    end
    if definition.requiresTech and not hasFactionTech(factionId, definition.requiresTech) then
        outputChatBox("[Dominação] Sua facção ainda não desbloqueou esta tecnologia.", player, 255, 120, 80)
        return
    end
    if definition.max and getFactionModuleCount(factionId, moduleType) >= definition.max then
        outputChatBox("[Dominação] Limite de módulos deste tipo atingido.", player, 255, 120, 80)
        return
    end
    if not hasFactionResources(factionId, definition.cost) then
        outputChatBox("[Dominação] Recursos insuficientes. Necessário: " .. formatResourceList(definition.cost), player, 255, 120, 80)
        return
    end

    local x, y, z = getElementPosition(player)
    local interior = getElementInterior(player)
    local dimension = getElementDimension(player)

    if not consumeFactionResources(factionId, definition.cost) then
        outputChatBox("[Dominação] Falha ao consumir recursos.", player, 255, 120, 80)
        return
    end

    local moduleId = insertModuleRecord(factionId, moduleType, x, y, z, interior, dimension, definition.health)
    local object = createModule(factionId, moduleType, x, y, z, interior, dimension, definition.health)
    if object then
        setElementData(object, "domination:moduleId", moduleId, false)
        outputChatBox("[Dominação] Módulo " .. definition.name .. " construído.", player, 90, 220, 90)
        logs:dbLog(player, 4, player, "Domination module built: faction " .. factionId .. " type " .. moduleType)
        exports.factions:sendNotiToAllFactionMembers(factionId, "Novo Módulo", definition.name .. " construído por " .. getPlayerName(player) .. ".", true)
        if moduleType == "research" then
            resumeFactionResearch(factionId)
        end
    else
        outputChatBox("[Dominação] Falha ao construir o módulo.", player, 255, 120, 80)
    end
end)

addCommandHandler("factionresearch", function(player, command, techId, boost)
    if isCommandOnCooldown(player, command) then
        outputChatBox("[Dominação] Aguarde antes de repetir o comando.", player, 255, 160, 120)
        return
    end
    local factionId = getPrimaryFactionId(player)
    if not factionId then
        outputChatBox("[Dominação] Você precisa estar em uma facção.", player, 255, 120, 80)
        return
    end
    if not isFactionLeader(player, factionId) then
        outputChatBox("[Dominação] Apenas líderes podem iniciar pesquisas.", player, 255, 120, 80)
        return
    end
    if not techId then
        outputChatBox("[Dominação] Tecnologias disponíveis:", player, 255, 200, 120)
        for key, tech in pairs(TECH_DEFINITIONS) do
            outputChatBox(" - " .. key .. " (" .. tech.name .. ")", player, 255, 200, 120)
        end
        return
    end
    techId = string.lower(techId)
    local tech = TECH_DEFINITIONS[techId]
    if not tech then
        outputChatBox("[Dominação] Tecnologia inválida.", player, 255, 120, 80)
        return
    end
    if not hasFactionTech(factionId, techId) then
        local qh = dbQuery(mysql:getConn("mta"), "SELECT status FROM domination_faction_research WHERE faction_id = ?", factionId)
        local result = dbPoll(qh, 10000)
        if result and result[1] and result[1].status == "active" then
            outputChatBox("[Dominação] Sua facção já possui uma pesquisa ativa.", player, 255, 120, 80)
            return
        end
        if countFactionModulesByType(factionId, "research") < 1 then
            outputChatBox("[Dominação] Você precisa de um Centro de Pesquisa para iniciar.", player, 255, 120, 80)
            return
        end
        for _, requirement in ipairs(tech.requires or {}) do
            if not hasFactionTech(factionId, requirement) then
                outputChatBox("[Dominação] Requisito faltando: " .. requirement, player, 255, 120, 80)
                return
            end
        end
        local duration = tech.duration
        if boost and string.lower(boost) == "boost" then
            if updateResearchBoost(player) then
                duration = math.floor(duration * RESEARCH_BOOST_FACTOR)
                outputChatBox("[Dominação] Boost aplicado. Tempo reduzido.", player, 90, 220, 90)
            else
                outputChatBox("[Dominação] Você não possui boosts de pesquisa.", player, 255, 120, 80)
                return
            end
        end
        local endTimestamp = nowTimestamp() + duration
        dbExec(mysql:getConn("mta"), "REPLACE INTO domination_faction_research (faction_id, tech_id, status, remaining_seconds, started_at, ends_at, ends_at_ts, updated_at) VALUES (?, ?, 'active', ?, NOW(), FROM_UNIXTIME(?), ?, NOW())", factionId, techId, duration, endTimestamp, endTimestamp)
        if researchTimers[factionId] then
            killTimer(researchTimers[factionId])
        end
        researchTimers[factionId] = setTimer(function()
            triggerEvent("domination:researchComplete", resourceRoot, factionId, techId)
        end, duration * 1000, 1)
        exports.factions:sendNotiToAllFactionMembers(factionId, "Pesquisa Iniciada", "Tecnologia " .. tech.name .. " em andamento.", true)
        logs:dbLog(player, 4, player, "Domination research started: faction " .. factionId .. " tech " .. techId)
    else
        outputChatBox("[Dominação] Sua facção já concluiu esta tecnologia.", player, 255, 120, 80)
    end
end)

addCommandHandler("factionstock", function(player)
    local factionId = getPrimaryFactionId(player)
    if not factionId then
        outputChatBox("[Dominação] Você precisa estar em uma facção.", player, 255, 120, 80)
        return
    end
    local stock = ensureFactionStock(factionId)
    outputChatBox("[Dominação] Estoque da facção:", player, 255, 200, 120)
    outputChatBox("Óleo: " .. stock.oil .. " | Aço: " .. stock.steel .. " | Componentes: " .. stock.components .. " | Elite: " .. stock.elite_components, player, 255, 200, 120)
end)

addCommandHandler("declarewar", function(player, command, targetId)
    if isCommandOnCooldown(player, command) then
        outputChatBox("[Dominação] Aguarde antes de repetir o comando.", player, 255, 160, 120)
        return
    end
    local factionId = getPrimaryFactionId(player)
    if not factionId then
        outputChatBox("[Dominação] Você precisa estar em uma facção.", player, 255, 120, 80)
        return
    end
    if not isFactionLeader(player, factionId) then
        outputChatBox("[Dominação] Apenas líderes podem declarar guerra.", player, 255, 120, 80)
        return
    end
    local targetFaction = tonumber(targetId)
    if not targetFaction then
        outputChatBox("Uso: /declarewar <id da facção>", player, 255, 200, 120)
        return
    end
    if targetFaction == factionId then
        outputChatBox("[Dominação] Não é possível declarar guerra contra sua própria facção.", player, 255, 120, 80)
        return
    end
    local qh = dbQuery(mysql:getConn("mta"), "SELECT MAX(UNIX_TIMESTAMP(created_at)) AS last_time FROM domination_wars WHERE (attacker_id=? OR defender_id=?)", factionId, factionId)
    local result = dbPoll(qh, 10000)
    if result and result[1] and result[1].last_time then
        local lastTime = tonumber(result[1].last_time)
        if lastTime and (nowTimestamp() - lastTime) < (WAR_SETTINGS.cooldownHours * 3600) then
            outputChatBox("[Dominação] Sua facção precisa aguardar para declarar outra guerra.", player, 255, 120, 80)
            return
        end
    end
    local startTimestamp = nowTimestamp() + (WAR_SETTINGS.delayMinutes * 60)
    local endTimestamp = startTimestamp + (WAR_SETTINGS.windowMinutes * 60)
    dbExec(mysql:getConn("mta"), "INSERT INTO domination_wars (attacker_id, defender_id, start_time, end_time, status, created_at) VALUES (?, ?, FROM_UNIXTIME(?), FROM_UNIXTIME(?), 'scheduled', NOW())", factionId, targetFaction, startTimestamp, endTimestamp)
    local qh2 = dbQuery(mysql:getConn("mta"), "SELECT LAST_INSERT_ID() AS id")
    local result2 = dbPoll(qh2, 10000)
    local warId = result2 and result2[1] and tonumber(result2[1].id)
    if warId then
        activeWars[warId] = { attacker = factionId, defender = targetFaction, status = "scheduled", start_ts = startTimestamp, end_ts = endTimestamp }
        scheduleWarTimers(warId, factionId, targetFaction, startTimestamp, endTimestamp)
        outputChatBox("[Dominação] Guerra declarada. A janela começará em " .. WAR_SETTINGS.delayMinutes .. " minutos.", player, 255, 180, 120)
        exports.factions:sendNotiToAllFactionMembers(targetFaction, "Guerra Declarada", "A facção " .. factionId .. " declarou guerra. Preparem-se para o cerco.", true)
        logs:dbLog(player, 4, player, "Domination war declared: attacker " .. factionId .. " defender " .. targetFaction)
    end
end)

local function createLogisticsMarkers()
    for _, route in ipairs(LOGISTICS_ROUTES) do
        local marker = createMarker(route.start.x, route.start.y, route.start.z - 1, "cylinder", 3, 90, 180, 255, 150)
        setElementData(marker, "domination:routeId", route.id, false)
        addEventHandler("onMarkerHit", marker, function(player, matchingDimension)
            if not matchingDimension or getElementType(player) ~= "player" then
                return
            end
            if not isPedInVehicle(player) then
                outputChatBox("[Dominação] Você precisa estar em um veículo para iniciar a rota.", player, 255, 120, 80)
                return
            end
            executeCommandHandler("logisticsstart", player, tostring(route.id))
        end)
    end
end

addCommandHandler("logistics", function(player)
    outputChatBox("[Dominação] Rotas de logística disponíveis:", player, 255, 200, 120)
    for _, route in ipairs(LOGISTICS_ROUTES) do
        outputChatBox(string.format("%d) %s (Risco: %s)", route.id, route.name, route.risk), player, 255, 200, 120)
    end
end)

addCommandHandler("logisticsstart", function(player, command, routeId)
    if isCommandOnCooldown(player, command) then
        outputChatBox("[Dominação] Aguarde antes de repetir o comando.", player, 255, 160, 120)
        return
    end
    if not isPedInVehicle(player) then
        outputChatBox("[Dominação] Você precisa estar em um veículo.", player, 255, 120, 80)
        return
    end
    local factionId = getPrimaryFactionId(player)
    if not factionId then
        outputChatBox("[Dominação] Apenas membros de facção podem transportar recursos.", player, 255, 120, 80)
        return
    end
    routeId = tonumber(routeId)
    local route
    for _, entry in ipairs(LOGISTICS_ROUTES) do
        if entry.id == routeId then
            route = entry
            break
        end
    end
    if not route then
        outputChatBox("[Dominação] Rota inválida.", player, 255, 120, 80)
        return
    end
    local px, py, pz = getElementPosition(player)
    if getDistanceBetweenPoints3D(px, py, pz, route.start.x, route.start.y, route.start.z) > 12 then
        outputChatBox("[Dominação] Você precisa estar no ponto de coleta da rota.", player, 255, 120, 80)
        return
    end
    if route.requiresTech and not hasFactionTech(factionId, route.requiresTech) then
        outputChatBox("[Dominação] Sua facção ainda não desbloqueou esta rota.", player, 255, 120, 80)
        return
    end
    if activeRoutes[player] then
        outputChatBox("[Dominação] Você já está em uma rota ativa.", player, 255, 120, 80)
        return
    end
    local marker = createMarker(route.destination.x, route.destination.y, route.destination.z - 1, "checkpoint", 4, 90, 255, 120, 150)
    activeRoutes[player] = {
        factionId = factionId,
        route = route,
        marker = marker,
        vehicle = getPedOccupiedVehicle(player),
        startedAt = nowTimestamp(),
    }
    outputChatBox("[Dominação] Rota iniciada: " .. route.name .. ". Entregue a carga no destino.", player, 90, 220, 90)
    logs:dbLog(player, 4, player, "Domination logistics started: route " .. route.id)

    addEventHandler("onMarkerHit", marker, function(hitPlayer, matchingDimension)
        if not matchingDimension or hitPlayer ~= player then
            return
        end
        local active = activeRoutes[player]
        if not active or active.marker ~= marker then
            return
        end
        if active.vehicle ~= getPedOccupiedVehicle(player) then
            outputChatBox("[Dominação] Entrega inválida. Use o mesmo veículo da coleta.", player, 255, 120, 80)
            return
        end
        local reward = {}
        for _, key in ipairs(RESOURCE_TYPES) do
            reward[key] = active.route.reward[key] or 0
        end
        if hasFactionTech(factionId, "logistics") then
            for _, key in ipairs(RESOURCE_TYPES) do
                reward[key] = math.floor(reward[key] * 1.1)
            end
        end
        local contractUsed = false
        if getPerkCount(player, LOGISTICS_CONTRACT_PERK_ID) > 0 then
            contractUsed = applyLogisticsContract(player)
        end
        if contractUsed then
            for _, key in ipairs(RESOURCE_TYPES) do
                reward[key] = reward[key] * LOGISTICS_CONTRACT_MULTIPLIER
            end
            outputChatBox("[Dominação] Contrato prioritário aplicado. Entrega em dobro.", player, 90, 220, 90)
        end
        adjustFactionStock(factionId, reward)
        exports.global:giveMoney(player, 750, true)
        exports.factions:sendNotiToAllFactionMembers(factionId, "Entrega Concluída", "Recursos adicionados ao depósito.", false)
        logs:dbLog(player, 4, player, "Domination logistics delivered: route " .. active.route.id .. " faction " .. factionId)
        outputChatBox("[Dominação] Entrega concluída. Recompensa: " .. formatResourceList(reward) .. ".", player, 90, 220, 90)
        if isElement(marker) then
            destroyElement(marker)
        end
        activeRoutes[player] = nil
    end)

    setTimer(function()
        if activeRoutes[player] and activeRoutes[player].marker == marker then
            if isElement(marker) then
                destroyElement(marker)
            end
            activeRoutes[player] = nil
            outputChatBox("[Dominação] A rota expirou.", player, 255, 120, 80)
        end
    end, 1800000, 1)
end)

addCommandHandler("repairkit", function(player)
    if not isPedInVehicle(player) then
        outputChatBox("[Dominação] Você precisa estar em um veículo para usar o kit.", player, 255, 120, 80)
        return
    end
    local vehicle = getPedOccupiedVehicle(player)
    local factionId = getElementData(vehicle, "faction")
    if tonumber(factionId or -1) > 0 then
        outputChatBox("[Dominação] Kits emergenciais são apenas para veículos civis.", player, 255, 120, 80)
        return
    end
    if not applyRepairKit(player) then
        outputChatBox("[Dominação] Você não possui kits de reparo.", player, 255, 120, 80)
        return
    end
    fixVehicle(vehicle)
    outputChatBox("[Dominação] Veículo reparado com sucesso.", player, 90, 220, 90)
    logs:dbLog(player, 4, player, "Domination repair kit used")
end)

addEventHandler("onPlayerQuit", root, function()
    if activeRoutes[source] then
        if activeRoutes[source].marker and isElement(activeRoutes[source].marker) then
            destroyElement(activeRoutes[source].marker)
        end
        activeRoutes[source] = nil
    end
end)

addEventHandler("onResourceStart", resourceRoot, function()
    exports.mysql:createMigrations(resourceName, {
        [[CREATE TABLE IF NOT EXISTS domination_faction_stock (
            faction_id INT NOT NULL PRIMARY KEY,
            oil INT NOT NULL DEFAULT 0,
            steel INT NOT NULL DEFAULT 0,
            components INT NOT NULL DEFAULT 0,
            elite_components INT NOT NULL DEFAULT 0,
            control_points INT NOT NULL DEFAULT 0
        )]],
        [[CREATE TABLE IF NOT EXISTS domination_faction_modules (
            id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
            faction_id INT NOT NULL,
            module_type VARCHAR(32) NOT NULL,
            x DOUBLE NOT NULL,
            y DOUBLE NOT NULL,
            z DOUBLE NOT NULL,
            interior INT NOT NULL DEFAULT 0,
            dimension INT NOT NULL DEFAULT 0,
            health INT NOT NULL DEFAULT 0,
            created_at DATETIME NOT NULL,
            updated_at DATETIME NOT NULL
        )]],
        [[CREATE TABLE IF NOT EXISTS domination_faction_research (
            faction_id INT NOT NULL PRIMARY KEY,
            tech_id VARCHAR(32) NOT NULL,
            status VARCHAR(16) NOT NULL,
            remaining_seconds INT NOT NULL DEFAULT 0,
            started_at DATETIME NULL,
            ends_at DATETIME NULL,
            ends_at_ts INT NULL,
            updated_at DATETIME NOT NULL
        )]],
        [[CREATE TABLE IF NOT EXISTS domination_faction_techs (
            faction_id INT NOT NULL,
            tech_id VARCHAR(32) NOT NULL,
            completed_at DATETIME NOT NULL,
            PRIMARY KEY (faction_id, tech_id)
        )]],
        [[CREATE TABLE IF NOT EXISTS domination_wars (
            id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
            attacker_id INT NOT NULL,
            defender_id INT NOT NULL,
            start_time DATETIME NOT NULL,
            end_time DATETIME NOT NULL,
            status VARCHAR(16) NOT NULL,
            winner_id INT NULL,
            created_at DATETIME NOT NULL
        )]],
        [[CREATE TABLE IF NOT EXISTS domination_cosmetics (
            account_id INT NOT NULL PRIMARY KEY,
            slots INT NOT NULL DEFAULT 0,
            selected_skin INT NULL,
            updated_at DATETIME NOT NULL
        )]],
    })

    setupZones()
    loadModules()
    loadResearch()
    loadWars()
    createLogisticsMarkers()
    setupEventTimers()
    outputDebugString("[Dominação] Sistema carregado.")
end)

function grantCosmeticSlot(player, amount)
    if not isElement(player) then
        return false
    end
    local accountId = getElementData(player, "account:id")
    if not accountId then
        return false
    end
    amount = tonumber(amount) or 1
    local qh = dbQuery(mysql:getConn("mta"), "SELECT slots FROM domination_cosmetics WHERE account_id=?", accountId)
    local result = dbPoll(qh, 10000)
    local slots = amount
    if result and result[1] then
        slots = math.max(tonumber(result[1].slots) or 0, amount)
        dbExec(mysql:getConn("mta"), "UPDATE domination_cosmetics SET slots=?, updated_at=NOW() WHERE account_id=?", slots, accountId)
    else
        dbExec(mysql:getConn("mta"), "INSERT INTO domination_cosmetics (account_id, slots, updated_at) VALUES (?, ?, NOW())", accountId, slots)
    end
    return true
end

addEventHandler("onPlayerLogin", root, function()
    local accountId = getElementData(source, "account:id")
    if not accountId then
        return
    end
    local perkCount = getPerkCount(source, COSMETIC_SLOT_PERK_ID)
    if perkCount > 0 then
        grantCosmeticSlot(source, perkCount)
    end
end)
