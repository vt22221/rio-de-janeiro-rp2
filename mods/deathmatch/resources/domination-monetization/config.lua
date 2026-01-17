-- Regras VIP:
-- 1) Apenas um tier ativo por conta; o maior tier prevalece.
-- 2) Comprar o mesmo ou menor tier estende a data final (stack de tempo), sem empilhar multiplicadores.
-- 3) Assinaturas sempre duram 30 dias por unidade (mensal).
VIP_TIERS = {
    basic = {
        name = "Basic",
        durationDays = 30,
        researchMultiplier = 0.95,
        logisticsMultiplier = 1.05,
        productionMultiplier = 1.05,
    },
    elite = {
        name = "Elite",
        durationDays = 30,
        researchMultiplier = 0.9,
        logisticsMultiplier = 1.1,
        productionMultiplier = 1.1,
    },
    warlord = {
        name = "Warlord",
        durationDays = 30,
        researchMultiplier = 0.85,
        logisticsMultiplier = 1.15,
        productionMultiplier = 1.15,
    },
}

VIP_TIER_ORDER = {
    basic = 1,
    elite = 2,
    warlord = 3,
}

-- Regras de boost:
-- 1) Apenas um boost ativo por escopo+tipo.
-- 2) Recompra durante a vigência estende o tempo até o limite stackMaxSeconds.
-- 3) Cooldown inicia quando o boost expira (cooldownSeconds).
BOOST_DEFINITIONS = {
    research = {
        name = "Pesquisa Soberana",
        durationSeconds = 3600,
        cooldownSeconds = 7200,
        stackMaxSeconds = 7200,
        multiplier = 0.8,
    },
    logistics = {
        name = "Logística Soberana",
        durationSeconds = 3600,
        cooldownSeconds = 7200,
        stackMaxSeconds = 7200,
        multiplier = 1.25,
    },
    production = {
        name = "Produção Soberana",
        durationSeconds = 3600,
        cooldownSeconds = 7200,
        stackMaxSeconds = 7200,
        multiplier = 1.25,
    },
}
