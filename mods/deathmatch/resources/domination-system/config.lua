RESOURCE_TYPES = {
    "oil",
    "steel",
    "components",
    "elite_components",
}

MODULE_DEFINITIONS = {
    command = {
        name = "Centro de Comando",
        model = 11312,
        health = 5000,
        max = 1,
        cost = { oil = 80, steel = 120, components = 60, elite_components = 0 },
    },
    research = {
        name = "Centro de Pesquisa",
        model = 3115,
        health = 3500,
        max = 1,
        cost = { oil = 40, steel = 80, components = 40, elite_components = 0 },
    },
    depot = {
        name = "Depósito",
        model = 2934,
        health = 3000,
        max = 2,
        cost = { oil = 30, steel = 60, components = 25, elite_components = 0 },
    },
    factory = {
        name = "Fábrica de Guerra",
        model = 3578,
        health = 3200,
        max = 1,
        cost = { oil = 50, steel = 90, components = 70, elite_components = 10 },
    },
    defense = {
        name = "Defesa Básica",
        model = 2985,
        health = 2500,
        max = 6,
        cost = { oil = 20, steel = 40, components = 30, elite_components = 0 },
        requiresTech = "fortifications",
    },
}

TECH_DEFINITIONS = {
    logistics = {
        name = "Logística Otimizada",
        duration = 3600,
        requires = {},
        bonus = { logistics_bonus = 0.1 },
    },
    fortifications = {
        name = "Fortificações Básicas",
        duration = 4200,
        requires = { "logistics" },
        unlocks = { "defense" },
    },
    aerial = {
        name = "Programa Aéreo",
        duration = 5400,
        requires = { "logistics" },
        unlocks = { "air_assets" },
    },
    elite_components = {
        name = "Componentes de Elite",
        duration = 4800,
        requires = { "logistics" },
        unlocks = { "elite_components" },
    },
}

LOGISTICS_ROUTES = {
    {
        id = 1,
        name = "Porto Industrial → Base",
        start = { x = 2497.2, y = -2093.8, z = 13.6 },
        destination = { x = 1534.8, y = -1692.2, z = 13.4 },
        reward = { oil = 25, steel = 30, components = 20, elite_components = 0 },
        risk = "Alta",
    },
    {
        id = 2,
        name = "Refinaria → Fronteira",
        start = { x = 2774.1, y = -2436.5, z = 13.6 },
        destination = { x = 641.6, y = -1114.2, z = 23.0 },
        reward = { oil = 35, steel = 20, components = 10, elite_components = 0 },
        risk = "Média",
    },
    {
        id = 3,
        name = "Sucata Militar → Base",
        start = { x = 215.2, y = 1917.8, z = 17.6 },
        destination = { x = 1540.3, y = -1680.4, z = 13.5 },
        reward = { oil = 10, steel = 25, components = 35, elite_components = 5 },
        risk = "Extrema",
        requiresTech = "elite_components",
    },
}

ZONE_DEFINITIONS = {
    {
        id = 1,
        name = "Zona Segura Central",
        type = "safe",
        x = 1481.4,
        y = -1716.0,
        z = 13.5,
        radius = 220,
    },
    {
        id = 2,
        name = "Distrito de Comércio",
        type = "commerce",
        x = 1132.8,
        y = -1440.4,
        z = 15.0,
        radius = 180,
    },
    {
        id = 3,
        name = "Zona de Recursos",
        type = "resource",
        x = 2742.2,
        y = -2398.2,
        z = 13.6,
        radius = 260,
    },
    {
        id = 4,
        name = "Terra de Ninguém",
        type = "no_mans_land",
        x = 1010.4,
        y = 1622.3,
        z = 10.8,
        radius = 360,
    },
}

EVENT_SETTINGS = {
    convoyInterval = 3600,
    airdropInterval = 2700,
    convoyReward = { components = 40, elite_components = 10 },
    airdropReward = { oil = 20, steel = 20, components = 15, elite_components = 5 },
}

WAR_SETTINGS = {
    cooldownHours = 6,
    delayMinutes = 5,
    windowMinutes = 60,
}

ASSET_OPERATION_COSTS = {
    [432] = { oil = 4, steel = 2, components = 2 }, -- Rhino
    [425] = { oil = 5, steel = 1, components = 3 }, -- Hunter
    [520] = { oil = 6, steel = 1, components = 4 }, -- Hydra
}

RESEARCH_BOOST_PERK_ID = 44
LOGISTICS_CONTRACT_PERK_ID = 45
REPAIR_KIT_PERK_ID = 46
COSMETIC_SLOT_PERK_ID = 47

RESEARCH_BOOST_FACTOR = 0.75
LOGISTICS_CONTRACT_MULTIPLIER = 2

COMMAND_COOLDOWNS = {
    factionbuild = 3,
    factionresearch = 3,
    declarewar = 5,
    logisticsstart = 3,
}
