-- 50/50 v13
-- drums + bass sequencer / PolyPerc engine
-- K1: system | K2: play/stop | K3: randomize
-- K2 double-tap: tap tempo
-- enc1: bpm | enc2: drum pattern | enc3: bass pattern
-- grid rows 1-3 left : drum patterns
-- grid rows 1-3 right: bass patterns
-- grid row 4: playheads
-- grid row 5: divider
-- grid row 6: morph scrub
-- grid row 7 left: mute drums | right: mute bass
-- grid row 8: 16 save slots (hold 3s=save, tap=recall)
-- MIDI: drums ch1, bass ch2

engine.name = "PolyPerc"

local midi_out
local DRUM_CH      = 1
local BASS_CH      = 2
local grid_device
local clock_id
local morph_clock_id

-- see full source at https://claude.ai/chat/b3b7cd2c-71f0-49a1-aca6-ccf1b120dd54
