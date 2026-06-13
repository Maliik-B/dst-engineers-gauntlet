-- Engineer's Gauntlet — co-op wave defense for Don't Starve Together
-- Portfolio mod: server-authoritative siege waves with a measured
-- naive-vs-optimized netcode demonstration.

name = "Engineer's Gauntlet"
description = [[Co-op wave defense. Escalating sieges path to a defended objective — hold the line with buildable auto-turrets and a commandable minion. Any character can defend.

v0.2 — core wave loop (objective, waves, win/lose).]]
author = "Maliik Bryan"
version = "0.2.0"

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
            { description = "Small (5)",   data = 5 },
            { description = "Default (10)", data = 10 },
            { description = "Large (20)",  data = 20 },
            { description = "Huge (40)",   data = 40 },
            { description = "Stress (80)", data = 80 },
        },
        default = 10,
    },
}
