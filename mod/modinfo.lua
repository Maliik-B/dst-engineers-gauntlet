-- Engineer's Gauntlet — co-op wave defense for Don't Starve Together
-- Portfolio mod: server-authoritative siege waves with a measured
-- naive-vs-optimized netcode demonstration.

name = "Engineer's Gauntlet"
description = [[Hold the line. Plant your Engine, then weather escalating waves that march straight for it — they won't be kited into a maze, so it's just you and a thickening swarm.

Build auto-turrets, deploy a minion you can actually order around (hold this spot, follow me, or go kill that one), and when the Engine's down to its last sparks, patch it back together and run it again. Any character can play engineer.

Crank the waves from a gentle warm-up to a proper meat grinder.

• Craft and activate the Engine to start a run
• Three attackers: rushers, fast swarmers, and defense-breakers
• Buildable auto-turrets + a commandable minion
• On-screen siege HUD; examine your gear for its status
• Configurable wave count, size, and pacing]]
author = "TheMolunga"
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
