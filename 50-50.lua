-- 50/50
-- drums left / acid right
-- grid: left half = drum patterns, right half = acid bass patterns
-- each button press changes the loop on that side
-- auto-randomizes on load, everything clock-synced via MIDI out
--
-- E1: BPM
-- K2: randomize drums
-- K3: randomize bass
-- Grid left (cols 1-8): select drum loop
-- Grid right (cols 9-16): select bass loop
-- MIDI out: drums ch1, bass ch2

engine.name = "None"
