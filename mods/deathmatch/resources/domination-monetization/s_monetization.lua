mysql = exports.mysql
logs = exports.logs
factions = exports.factions

local resourceName = getResourceName(getThisResource())

local function nowTimestamp()
    return getRealTime().timestamp
end

local function getAccountId(player)
    if not isElement(player) then
        return nil
    end
    return tonumber(getElementData(player, "account:id"))
end

local function getVipRow(accountId)
    local qh = dbQuery(mysql:getConn("mta"), "SELECT tier, UNIX_TIMESTAMP(ends_at) AS ends_at_ts FROM domination_vip_subscriptions WHERE account_id=?", accountId)
    local result = dbPoll(qh, 10000)
    if result and result[1] then
        return result[1]
    end
    return nil
end

local function clearExpiredVip(accountId, row)
    if not row or not row.ends_at_ts then
        return nil
    end
    local now = nowTimestamp()
    if now >= tonumber(row.ends_at_ts) then
        dbExec(mysql:getConn("mta"), "DELETE FROM domination_vip_subscriptions WHERE account_id=?", accountId)
        return nil
    end
    return row
end

function getVipTier(player)
    local accountId = getAccountId(player) or tonumber(player)
    if not accountId then
        return nil
    end
    local row = getVipRow(accountId)
    row = clearExpiredVip(accountId, row)
    if not row then
        return nil
    end
    return row.tier, tonumber(row.ends_at_ts)
end

function grantVipSubscription(player, tier, months)
    local accountId = getAccountId(player) or tonumber(player)
    if not accountId then
        return false, "Conta inválida."
    end
    if not tier or not VIP_TIERS[tier] then
        return false, "Tier inválido."
    end
    months = tonumber(months) or 1
    if months < 1 then
        months = 1
    end

    local now = nowTimestamp()
    local row = getVipRow(accountId)
    row = clearExpiredVip(accountId, row)
    local currentTier = row and row.tier or nil
    local currentEnd = row and tonumber(row.ends_at_ts) or nil
    local baseTime = now
    if currentEnd and currentEnd > now then
        baseTime = currentEnd
    end

    local finalTier = tier
    if currentTier and VIP_TIER_ORDER[currentTier] and VIP_TIER_ORDER[currentTier] > (VIP_TIER_ORDER[tier] or 0) then
        finalTier = currentTier
    end

    local durationSeconds = (VIP_TIERS[tier].durationDays or 30) * 86400 * months
    local newEnd = baseTime + durationSeconds

    dbExec(mysql:getConn("mta"), "REPLACE INTO domination_vip_subscriptions (account_id, tier, starts_at, ends_at, created_at, updated_at) VALUES (?, ?, FROM_UNIXTIME(?), FROM_UNIXTIME(?), NOW(), NOW())", accountId, finalTier, now, newEnd)

    if isElement(player) then
        logs:dbLog(player, 4, player, "Domination VIP subscription: " .. tostring(finalTier) .. " expires " .. tostring(newEnd))
    end
    return true, finalTier, newEnd
end

local function getBoostRow(scope, targetId, boostType)
    local qh = dbQuery(mysql:getConn("mta"), "SELECT multiplier, UNIX_TIMESTAMP(starts_at) AS starts_at_ts, UNIX_TIMESTAMP(ends_at) AS ends_at_ts, UNIX_TIMESTAMP(cooldown_ends_at) AS cooldown_ends_at_ts FROM domination_boosts WHERE scope=? AND target_id=? AND boost_type=?", scope, targetId, boostType)
    local result = dbPoll(qh, 10000)
    if result and result[1] then
        return result[1]
    end
    return nil
end

local function setBoostRow(scope, targetId, boostType, multiplier, startsAt, endsAt, cooldownEndsAt, activatedBy)
    dbExec(mysql:getConn("mta"), [[REPLACE INTO domination_boosts
        (scope, target_id, boost_type, multiplier, starts_at, ends_at, cooldown_ends_at, last_activated_by, updated_at)
        VALUES (?, ?, ?, ?, FROM_UNIXTIME(?), FROM_UNIXTIME(?), FROM_UNIXTIME(?), ?, NOW())]],
        scope, targetId, boostType, multiplier, startsAt, endsAt, cooldownEndsAt, activatedBy)
end

function activateBoost(player, scope, targetId, boostType)
    local def = BOOST_DEFINITIONS[boostType]
    if not def then
        return false, "Boost inválido."
    end
    if scope ~= "player" and scope ~= "faction" then
        return false, "Escopo inválido."
    end
    targetId = tonumber(targetId)
    if not targetId then
        return false, "Destino inválido."
    end

    local now = nowTimestamp()
    local row = getBoostRow(scope, targetId, boostType)
    if row and row.ends_at_ts and tonumber(row.ends_at_ts) > now then
        local remaining = tonumber(row.ends_at_ts) - now
        if remaining >= def.stackMaxSeconds then
            return false, "Boost já está no limite de stack."
        end
        local newRemaining = math.min(remaining + def.durationSeconds, def.stackMaxSeconds)
        local newEnd = now + newRemaining
        local newCooldown = newEnd + def.cooldownSeconds
        local startTime = tonumber(row.starts_at_ts) or now
        local activatedBy = getAccountId(player)
        setBoostRow(scope, targetId, boostType, def.multiplier, startTime, newEnd, newCooldown, activatedBy)
        if isElement(player) then
            logs:dbLog(player, 4, player, "Domination boost stacked: " .. scope .. " " .. boostType .. " -> " .. tostring(newEnd))
        end
        return true, newEnd
    end

    if row and row.cooldown_ends_at_ts and tonumber(row.cooldown_ends_at_ts) > now then
        return false, "Boost em cooldown."
    end

    local newEnd = now + def.durationSeconds
    local newCooldown = newEnd + def.cooldownSeconds
    local activatedBy = getAccountId(player)
    setBoostRow(scope, targetId, boostType, def.multiplier, now, newEnd, newCooldown, activatedBy)

    if isElement(player) then
        logs:dbLog(player, 4, player, "Domination boost activated: " .. scope .. " " .. boostType .. " -> " .. tostring(newEnd))
    end
    return true, newEnd
end

function getBoostMultiplier(scope, targetId, boostType)
    local def = BOOST_DEFINITIONS[boostType]
    if not def then
        return 1
    end
    targetId = tonumber(targetId)
    if not targetId then
        return 1
    end
    local row = getBoostRow(scope, targetId, boostType)
    if not row or not row.ends_at_ts then
        return 1
    end
    if nowTimestamp() >= tonumber(row.ends_at_ts) then
        return 1
    end
    return tonumber(row.multiplier) or def.multiplier or 1
end

function getResearchMultiplier(player, factionId)
    local multiplier = 1
    local tier = getVipTier(player)
    if tier and VIP_TIERS[tier] then
        multiplier = multiplier * (VIP_TIERS[tier].researchMultiplier or 1)
    end
    local accountId = getAccountId(player)
    if accountId then
        multiplier = multiplier * getBoostMultiplier("player", accountId, "research")
    end
    if factionId then
        multiplier = multiplier * getBoostMultiplier("faction", factionId, "research")
    end
    return multiplier
end

function getLogisticsMultiplier(player, factionId)
    local multiplier = 1
    local tier = getVipTier(player)
    if tier and VIP_TIERS[tier] then
        multiplier = multiplier * (VIP_TIERS[tier].logisticsMultiplier or 1)
    end
    local accountId = getAccountId(player)
    if accountId then
        multiplier = multiplier * getBoostMultiplier("player", accountId, "logistics")
    end
    if factionId then
        multiplier = multiplier * getBoostMultiplier("faction", factionId, "logistics")
    end
    return multiplier
end

function getProductionMultiplier(factionId)
    local multiplier = 1
    factionId = tonumber(factionId)
    if not factionId then
        return multiplier
    end
    local bestVip = 1
    local players = factions:getPlayersInFaction(factionId) or {}
    for _, player in ipairs(players) do
        local tier = getVipTier(player)
        if tier and VIP_TIERS[tier] then
            local tierMultiplier = VIP_TIERS[tier].productionMultiplier or 1
            if tierMultiplier > bestVip then
                bestVip = tierMultiplier
            end
        end
    end
    multiplier = multiplier * bestVip
    multiplier = multiplier * getBoostMultiplier("faction", factionId, "production")
    return multiplier
end

function getBoostStatus(scope, targetId, boostType)
    targetId = tonumber(targetId)
    if not targetId then
        return nil
    end
    local row = getBoostRow(scope, targetId, boostType)
    if not row then
        return nil
    end
    return {
        startsAt = tonumber(row.starts_at_ts) or nil,
        endsAt = tonumber(row.ends_at_ts) or nil,
        cooldownEndsAt = tonumber(row.cooldown_ends_at_ts) or nil,
        multiplier = tonumber(row.multiplier) or nil,
    }
end

addEventHandler("onResourceStart", resourceRoot, function()
    exports.mysql:createMigrations(resourceName, {
        [[CREATE TABLE IF NOT EXISTS domination_vip_subscriptions (
            account_id INT NOT NULL PRIMARY KEY,
            tier VARCHAR(16) NOT NULL,
            starts_at DATETIME NOT NULL,
            ends_at DATETIME NOT NULL,
            created_at DATETIME NOT NULL,
            updated_at DATETIME NOT NULL
        )]],
        [[CREATE TABLE IF NOT EXISTS domination_boosts (
            scope VARCHAR(16) NOT NULL,
            target_id INT NOT NULL,
            boost_type VARCHAR(16) NOT NULL,
            multiplier DOUBLE NOT NULL,
            starts_at DATETIME NULL,
            ends_at DATETIME NULL,
            cooldown_ends_at DATETIME NULL,
            last_activated_by INT NULL,
            updated_at DATETIME NOT NULL,
            PRIMARY KEY (scope, target_id, boost_type)
        )]],
    })

    outputDebugString("[Dominação] Monetização soberana carregada.")
end)
