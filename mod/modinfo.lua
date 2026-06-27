-- Engineer's Gauntlet — co-op wave defense for Don't Starve Together
-- Portfolio mod: server-authoritative siege waves with a measured
-- naive-vs-optimized netcode demonstration.

name = "Engineer's Gauntlet"
description = [[Co-op wave defense. Escalating sieges path to a defended objective — hold the line with buildable auto-turrets and a commandable minion. Any character can defend.

v0.6 — playable end-to-end: spawn with a starter kit, then craft and activate the Engine to begin a run (and repair it if it falls). Three attacker types (rusher / fast swarm / defense-breaker), an on-screen siege HUD, examine-readable condition + commands, damage-tier wear, and configurable wave count / size / interval.]]
author = "Maliik Bryan"
version = "0.6.0"

api_version = 10

dst_compatible = true
dont_starve_compatible = false
reign_of_giants_compatible = false

-- Gameplay mod: runs on the server sim, replicates state to clients.
all_clients_require_mod = true
client_only_mod = false

server_filter_tags = { "wave defense", "co-op", "tower defense" }

configuration_options = {
    {
        name = "wave_size",
        label = "Wave Size",
        hover = "Base attackers per wave. This is the load dial.",
        options = {
            { description = "Small (4)",   data = 4 },
            { description = "Default (6)", data = 6 },
            { description = "Large (10)",  data = 10 },
            { description = "Huge (20)",   data = 20 },
            { description = "Stress (80)", data = 80 },
        },
        default = 6,
    },
    {
        name = "num_waves",
        label = "Waves to Survive",
        hover = "How many waves the Engine must hold before victory.",
        options = {
            { description = "Short (3)",     data = 3 },
            { description = "Default (5)",   data = 5 },
            { description = "Long (8)",      data = 8 },
            { description = "Marathon (12)", data = 12 },
        },
        default = 5,
    },
    {
        name = "wave_interval",
        label = "Wave Interval",
        hover = "Breathing room between waves, in seconds.",
        options = {
            { description = "Frantic (30s)", data = 30 },
            { description = "Default (60s)", data = 60 },
            { description = "Relaxed (90s)", data = 90 },
        },
        default = 60,
    },
}
