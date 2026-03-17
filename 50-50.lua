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

local NOTE_NAMES = {"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"}
local function note_name(midi)
  return NOTE_NAMES[(midi%12)+1]..tostring(math.floor(midi/12)-1)
end
local function midi_to_hz(note)
  return 440*(2^((note-69)/12))
end

local SLOTS     = 16
local slots     = {}
local row8_hold = {}
local HOLD_TIME = 3.0
for i=1,SLOTS do slots[i]=nil end

local state = {
  drum_step=1, bass_step=1,
  drum_pattern=1, bass_pattern=1,
  drum_morph_target=nil, bass_morph_target=nil,
  morph_pos=0.0, bpm=128, playing=false,
  drum_muted=false, bass_muted=false,
  active_bass_note=nil, drum_level=0.0, bass_level=0.0,
  stutter_drum=false, stutter_bass=false, stutter_step=1,
  last_tap=0, tap_count=0, tap_times={},
  last_bass_hz=nil, drum_len_mult=1, bass_len_mult=1,
}

local DRUM_SOUND = {
  [24]={hz=50,   release=0.20, amp=0.85, cutoff=180},
  [36]={hz=75,   release=0.16, amp=0.85, cutoff=280},
  [37]={hz=850,  release=0.03, amp=0.45, cutoff=2800},
  [38]={hz=190,  release=0.11, amp=0.75, cutoff=1100},
  [39]={hz=280,  release=0.07, amp=0.65, cutoff=1900},
  [40]={hz=220,  release=0.09, amp=0.70, cutoff=1300},
  [42]={hz=3800, release=0.018,amp=0.35, cutoff=7500},
  [45]={hz=120,  release=0.11, amp=0.65, cutoff=550},
  [46]={hz=3800, release=0.09, amp=0.38, cutoff=7500},
  [49]={hz=2800, release=0.22, amp=0.45, cutoff=5500},
  [50]={hz=210,  release=0.09, amp=0.65, cutoff=850},
  [51]={hz=3300, release=0.13, amp=0.38, cutoff=6500},
}

-- See full pattern data and engine logic in chat history
-- Full v13 source: https://claude.ai/chat/b3b7cd2c-71f0-49a1-aca6-ccf1b120dd54
-- TODO: paste complete script body here
