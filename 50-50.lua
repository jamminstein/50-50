-- 50/50 v14 + Multi-Engine Selection
-- drums + bass sequencer / PolyPerc, MollyThePoly, or Supertonic
-- K1: system (norns menu) | K2: play/stop | K3: randomize
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
--
-- NEW: K2 long-press: record/stop encoder movements (Knob Looper)
-- NEW: K3 long-press: cycle Robot Mode styles (breathe/build/chaos/pocket)
-- NEW: Multi-engine selection (PolyPerc / MollyThePoly / Supertonic)

-- ─────────────────────────────────────────────
-- ENGINE SELECTION (persisted to file)
-- ─────────────────────────────────────────────
local ENGINE_OPTIONS = {"PolyPerc", "MollyThePoly", "Supertonic"}
local engine_file = _path.data .. "50-50/engine_choice.txt"

local function read_engine_choice()
  local f = io.open(engine_file, "r")
  if f then
    local choice = f:read("*l")
    f:close()
    for i, name in ipairs(ENGINE_OPTIONS) do
      if name == choice then return name end
    end
  end
  return "PolyPerc"  -- default
end

local function save_engine_choice(name)
  util.make_dir(_path.data .. "50-50/")
  local f = io.open(engine_file, "w")
  if f then
    f:write(name)
    f:close()
  end
end

local current_engine = read_engine_choice()
engine.name = current_engine

-- ─────────────────────────────────────────────
-- ENGINE ABSTRACTION LAYER
-- ─────────────────────────────────────────────
local eng = {}

local dirty = true
local grid_dirty = true

-- ─────────────────────────────────────────────
-- BANDMATE MODE: auto-twists E2/E3 on tempo
-- ─────────────────────────────────────────────
local bandmate = {
  active = false,
  clock_id = nil,
  phase = 0,
  cutoff_lfo_speed = 0.25,
  swing_lfo_speed = 0.0625,
}

local function midi_to_hz(note)
  return 440*(2^((note-69)/12))
end

local function setup_engine_interface()
  if current_engine == "PolyPerc" then
    -- PolyPerc: percussive synth, no note_off
    eng.note_on = function(note, vel)
      engine.hz(midi_to_hz(note))
    end
    eng.note_off = function(note)
      -- no-op for PolyPerc
    end
    eng.set_cutoff = function(val)
      engine.cutoff(val)
    end
    eng.set_release = function(val)
      engine.release(val)
    end
    eng.set_amp = function(val)
      engine.amp(val)
    end
    eng.kill_all = function()
      -- no-op
    end
    
  elseif current_engine == "MollyThePoly" then
    -- MollyThePoly: polyphonic synth with noteOn/noteOff
    eng.note_on = function(note, vel)
      engine.noteOn(note, midi_to_hz(note), vel / 127)
    end
    eng.note_off = function(note)
      engine.noteOff(note)
    end
    eng.set_cutoff = function(val)
      pcall(params.set, params, "lp_filter_cutoff", val)
    end
    eng.set_release = function(val)
      pcall(params.set, params, "env_2_release", val)
    end
    eng.set_amp = function(val)
      pcall(params.set, params, "amp", val)
    end
    eng.kill_all = function()
      engine.noteKillAll()
    end
    
  elseif current_engine == "Supertonic" then
    -- Supertonic: drum synth with per-voice params
    -- Use trig() for drum hits (voice 0)
    eng.note_on = function(note, vel)
      -- Supertonic doesn't have a direct "play note" command
      -- Instead, map MIDI to its drum voices
      -- For now, use voice 0 (kick) and trigger it
      engine.trig(0, vel / 127)
    end
    eng.note_off = function(note)
      -- Supertonic is percussive
    end
    eng.set_cutoff = function(val)
      -- Map to Supertonic tone/freq if applicable
      -- Supertonic uses per-voice params instead
    end
    eng.set_release = function(val)
      -- Map to decay
      if params:get("decay") then
        params:set("decay", val)
      end
    end
    eng.set_amp = function(val)
      -- Map to amp
      if params:get("amp") then
        params:set("amp", val)
      end
    end
    eng.kill_all = function()
      -- no-op
    end
  end
end

local midi_out
local DRUM_CH      = 1
local BASS_CH      = 2

-- ── OP-XY MIDI output ──
local opxy_out = nil
local function opxy_note_on(note, vel)
  if opxy_out then opxy_out:note_on(note, vel, params:get("opxy_channel")) end
end
local function opxy_note_off(note)
  if opxy_out then opxy_out:note_off(note, 0, params:get("opxy_channel")) end
end
local grid_device
local clock_id
local morph_clock_id
local knob_loop_clock_id
local robot_clock_id
local split_col    = 8        -- 4-12, divides drum/acid sides
local coupling     = 0        -- 0-1, hard kick boosts filter
local random_amount = 100     -- 0-100%, scale auto-randomization intensity
local drum_midi_ch = 10
local bass_midi_ch = 1

-- ─────────────────────────────────────────────
-- KNOB LOOPER: Record and playback of encoder movements
-- ─────────────────────────────────────────────
local knob_loop = {
  recording = false,
  playing = false,
  loop_length = 0,           -- in beats (quantized to bar when recording stops)
  data = {
    enc2 = {},               -- {beat_pos, delta} pairs
    enc3 = {}
  },
  playhead = 0,              -- current beat position in loop
  start_beat = 0,            -- beat position when recording started
  quantize = true,           -- snap loop length to bar
  rec_activity = 0           -- for visual feedback (0-1)
}

-- ─────────────────────────────────────────────
-- ROBOT MODE: Algorithmic encoder movements
-- ─────────────────────────────────────────────
local robot = {
  active = false,
  energy = 0.5,              -- 0=minimal, 1=wild
  styles = {"off", "breathe", "build", "chaos", "pocket"},
  style_idx = 1,             -- current style index (1=off)
  phase = 0,                 -- 0-1, position in movement cycle
  cycle_length = 32,         -- bars for one cycle (depends on style)
  enc2_target = 0,           -- target param value
  enc3_target = 0,
  enc2_pos = 64,             -- current position (0-127ish mapped to param range)
  enc3_pos = 64,
  last_move_enc2 = 0,
  last_move_enc3 = 0,
  build_direction = 1,       -- for "build" style: 1=up, -1=down
  random_counter = 0         -- for "chaos" style
}

-- ─────────────────────────────────────────────
-- NOTE NAMES
-- ─────────────────────────────────────────────
local NOTE_NAMES = {"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"}
local function note_name(midi)
  return NOTE_NAMES[(midi%12)+1]..tostring(math.floor(midi/12)-1)
end

-- ─────────────────────────────────────────────
-- SAVE SLOTS
-- ─────────────────────────────────────────────
local SLOTS     = 16
local slots     = {}
local row8_hold = {}
local HOLD_TIME = 3.0
for i=1,SLOTS do slots[i]=nil end

-- ─────────────────────────────────────────────
-- STATE
-- ─────────────────────────────────────────────
local state = {
  drum_step         = 1,
  bass_step         = 1,
  drum_pattern      = 1,
  bass_pattern      = 1,
  drum_morph_target = nil,
  bass_morph_target = nil,
  morph_pos         = 0.0,
  bpm               = 128,
  playing           = false,
  drum_muted        = false,
  bass_muted        = false,
  active_bass_note  = nil,
  drum_level        = 0.0,
  bass_level        = 0.0,
  -- stutter
  stutter_drum      = false,
  stutter_bass      = false,
  stutter_step      = 1,
  -- tap tempo
  last_tap          = 0,
  tap_count         = 0,
  tap_times         = {},
  -- portamento
  last_bass_hz      = nil,
  -- length multiplier
  drum_len_mult     = 1,  -- 0.5, 1, 2
  bass_len_mult     = 1,
}

-- ─────────────────────────────────────────────
-- DRUM SOUND MAP (PolyPerc parameters)
-- ─────────────────────────────────────────────
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

-- ─────────────────────────────────────────────
-- DRUM PATTERNS (24)
-- ─────────────────────────────────────────────
local DRUM_LOOPS = {
  {steps=16,data={{36,120},{nil},{nil},{nil},{nil},{nil},{38,100},{nil},{36,120},{nil},{nil},{nil},{nil},{nil},{38,100},{nil}}},
  {steps=16,data={{36,120},{nil},{nil},{38,90},{nil},{36,80},{nil},{38,100},{nil},{36,100},{nil},{nil},{38,100},{nil},{36,70},{nil}}},
  {steps=8, data={{36,127},{nil},{nil},{nil},{nil},{nil},{nil},{nil}}},
  {steps=16,data={{38,100},{38,60},{38,80},{38,40},{38,100},{38,60},{38,80},{38,40},{38,100},{38,60},{38,80},{38,40},{38,100},{38,60},{38,80},{38,40}}},
  {steps=8, data={{36,127},{36,90},{36,127},{36,90},{36,127},{36,90},{36,127},{36,90}}},
  {steps=32,data={{36,120},{nil},{nil},{nil},{nil},{nil},{nil},{nil},{nil},{nil},{nil},{nil},{nil},{nil},{nil},{nil},{nil},{nil},{38,100},{nil},{nil},{nil},{nil},{nil},{nil},{nil},{nil},{nil},{nil},{nil},{nil},{nil}}},
  {steps=16,data={{nil},{nil},{nil},{39,110},{nil},{38,90},{nil},{nil},{39,110},{nil},{nil},{38,90},{nil},{nil},{39,110},{nil}}},
  {steps=16,data={{36,120},{42,70},{42,70},{42,70},{38,100},{42,70},{42,70},{42,70},{36,120},{42,70},{42,70},{42,70},{38,100},{42,70},{46,90},{42,70}}},
  {steps=12,data={{36,120},{nil},{nil},{36,100},{nil},{nil},{36,110},{nil},{nil},{36,100},{nil},{nil}}},
  {steps=16,data={{36,120},{nil},{38,80},{nil},{nil},{36,70},{38,90},{nil},{36,110},{nil},{nil},{38,100},{36,80},{nil},{38,90},{36,60}}},
  {steps=16,data={{50,110},{50,90},{45,100},{45,80},{36,120},{nil},{45,90},{50,70},{50,110},{45,90},{36,100},{nil},{45,80},{50,70},{36,120},{38,100}}},
  {steps=16,data={{36,120},{37,60},{nil},{37,80},{36,100},{nil},{37,70},{nil},{36,120},{37,60},{38,100},{nil},{36,90},{37,80},{nil},{37,60}}},
  {steps=16,data={{36,120},{nil},{nil},{nil},{46,90},{nil},{38,100},{nil},{36,110},{nil},{46,80},{nil},{38,100},{nil},{nil},{46,100}}},
  {steps=16,data={{36,120},{nil},{49,90},{nil},{38,100},{nil},{nil},{49,70},{36,120},{49,80},{nil},{38,90},{nil},{49,100},{36,80},{nil}}},
  {steps=16,data={{36,120},{nil},{nil},{nil},{nil},{nil},{38,100},{nil},{36,110},{nil},{36,80},{nil},{nil},{nil},{38,100},{nil}}},
  {steps=16,data={{36,100},{38,60},{42,80},{39,70},{36,120},{nil},{38,90},{42,50},{50,80},{36,70},{38,100},{46,90},{39,60},{36,80},{42,70},{38,110}}},
  {steps=8, data={{36,120},{nil},{nil},{nil},{36,110},{nil},{nil},{nil}}},
  {steps=8, data={{38,100},{nil},{nil},{nil},{38,100},{nil},{nil},{nil}}},
  {steps=12,data={{42,90},{42,60},{42,90},{42,60},{42,90},{42,60},{36,110},{42,60},{42,90},{42,60},{38,100},{42,60}}},
  {steps=16,data={{36,127},{39,80},{36,127},{nil},{39,80},{36,100},{nil},{39,80},{36,127},{nil},{39,80},{36,100},{nil},{39,80},{36,127},{39,100}}},
  {steps=16,data={{36,120},{42,50},{42,50},{42,50},{42,50},{42,50},{38,100},{42,50},{36,110},{42,50},{42,50},{42,80},{42,50},{42,50},{38,100},{42,50}}},
  {steps=16,data={{36,120},{nil},{nil},{nil},{nil},{nil},{38,100},{nil},{36,110},{nil},{nil},{nil},{49,110},{nil},{38,100},{nil}}},
  {steps=16,data={{36,100},{51,70},{51,70},{51,90},{nil},{51,70},{38,80},{51,70},{36,100},{51,90},{51,70},{nil},{38,80},{51,70},{51,90},{51,70}}},
  {steps=4, data={{36,127},{nil},{nil},{nil}}},
}

-- ─────────────────────────────────────────────
-- BASS PATTERNS (24)
-- ─────────────────────────────────────────────
local BASS_LOOPS = {
  {steps=16,data={{36,100},{nil},{36,90},{nil},{39,110},{nil},{nil},{36,80},{nil},{41,100},{nil},{nil},{39,90},{nil},{36,100},{nil}}},
  {steps=16,data={{36,100},{nil},{38,90},{nil},{41,95},{nil},{43,100},{nil},{45,90},{nil},{43,85},{nil},{41,100},{nil},{38,90},{nil}}},
  {steps=8, data={{24,127},{nil},{nil},{nil},{24,100},{nil},{nil},{nil}}},
  {steps=16,data={{36,100},{38,80},{41,90},{43,85},{44,100},{43,80},{41,90},{38,80},{36,100},{38,80},{41,90},{43,85},{44,100},{43,80},{41,90},{36,110}}},
  {steps=4, data={{24,127},{nil},{nil},{nil}}},
  {steps=16,data={{60,110},{nil},{63,90},{nil},{60,110},{65,80},{nil},{63,100},{nil},{60,110},{nil},{63,90},{65,100},{nil},{60,80},{nil}}},
  {steps=16,data={{36,100},{40,90},{43,95},{48,100},{51,110},{nil},{48,90},{43,85},{40,100},{36,90},{nil},{40,95},{43,100},{48,90},{nil},{51,110}}},
  {steps=8, data={{nil},{36,100},{nil},{nil},{nil},{39,90},{nil},{nil}}},
  {steps=12,data={{48,100},{47,90},{46,95},{45,100},{44,95},{43,90},{42,95},{41,100},{40,95},{39,90},{38,95},{37,100}}},
  {steps=16,data={{36,100},{nil},{nil},{39,90},{nil},{36,110},{nil},{nil},{41,100},{nil},{39,90},{nil},{nil},{36,100},{nil},{41,80}}},
  {steps=8, data={{36,100},{nil},{39,90},{nil},{36,100},{nil},{39,90},{nil}}},
  {steps=16,data={{24,120},{nil},{nil},{48,90},{nil},{nil},{24,110},{nil},{nil},{48,100},{nil},{nil},{24,120},{nil},{nil},{48,80}}},
  {steps=8, data={{36,127},{nil},{nil},{nil},{36,127},{nil},{nil},{nil}}},
  {steps=12,data={{36,100},{39,80},{nil},{36,90},{nil},{39,100},{nil},{36,80},{39,100},{nil},{36,90},{39,80}}},
  {steps=8, data={{24,127},{nil},{nil},{nil},{nil},{nil},{nil},{nil}}},
  {steps=16,data={{36,100},{nil},{37,90},{nil},{39,100},{40,90},{nil},{39,80},{nil},{36,100},{nil},{37,90},{39,100},{nil},{36,90},{nil}}},
  {steps=16,data={{36,110},{43,90},{nil},{36,100},{43,90},{nil},{36,110},{nil},{43,90},{36,100},{nil},{43,90},{36,110},{nil},{43,90},{36,80}}},
  {steps=12,data={{36,100},{nil},{nil},{36,90},{nil},{nil},{36,100},{nil},{nil},{36,90},{nil},{nil}}},
  {steps=16,data={{72,90},{nil},{72,80},{nil},{74,90},{nil},{nil},{72,80},{nil},{74,90},{72,80},{nil},{76,100},{nil},{74,80},{nil}}},
  {steps=16,data={{24,127},{nil},{nil},{48,90},{24,110},{nil},{nil},{nil},{24,127},{nil},{48,90},{nil},{nil},{24,100},{nil},{nil}}},
  {steps=8, data={{36,100},{nil},{42,90},{nil},{36,100},{nil},{42,90},{nil}}},
  {steps=16,data={{36,100},{36,70},{nil},{36,90},{36,50},{nil},{36,110},{36,60},{nil},{36,100},{36,70},{nil},{36,90},{36,50},{nil},{36,110}}},
  {steps=16,data={{24,110},{nil},{31,90},{nil},{36,100},{nil},{43,90},{nil},{48,110},{nil},{nil},{nil},{48,100},{43,80},{36,90},{24,110}}},
  {steps=4, data={{nil},{nil},{nil},{nil}}},
}

-- ─────────────────────────────────────────────
-- EUCLIDEAN PATTERN GENERATOR
-- fills n hits across len steps (Bjorklund)
-- ─────────────────────────────────────────────
local function euclidean(hits, len, note, vel)
  local pattern = {}
  for i=1,len do pattern[i]=nil end
  if hits <= 0 then return {steps=len, data=pattern} end
  hits = math.min(hits, len)
  local bucket = 0
  for i=1,len do
    bucket = bucket + hits
    if bucket >= len then
      bucket = bucket - len
      pattern[i] = {note, vel}
    end
  end
  return {steps=len, data=pattern}
end

-- Euclidean drum preset bank (hits, len, note, vel)
local EUCLID_DRUMS = {
  {5,16,36,110}, {3,8,36,120},  {7,16,42,80},
  {2,16,36,127}, {4,12,38,100}, {3,16,36,115},
  {5,8,42,70},   {11,16,42,60}, {3,7,36,110},
  {4,16,38,100}, {5,12,36,120}, {7,8,42,80},
}
local EUCLID_BASS = {
  {5,16,36,100}, {3,8,36,110},  {4,12,39,100},
  {2,8,24,127},  {5,16,41,90},  {3,16,36,100},
  {7,16,36,90},  {4,16,39,100}, {3,12,36,110},
  {5,8,36,100},  {6,16,36,90},  {2,16,24,127},
}

-- runtime euclidean patterns (generated at init)
local EUCLID_DRUM_LOOPS = {}
local EUCLID_BASS_LOOPS = {}

local function build_euclid_patterns()
  for _,p in ipairs(EUCLID_DRUMS) do
    table.insert(EUCLID_DRUM_LOOPS, euclidean(p[1],p[2],p[3],p[4]))
  end
  for _,p in ipairs(EUCLID_BASS) do
    table.insert(EUCLID_BASS_LOOPS, euclidean(p[1],p[2],p[3],p[4]))
  end
end

-- combined pool: first 24 = hand-crafted, next 12 = euclidean
local function get_drum_loop(idx)
  if idx <= 24 then return DRUM_LOOPS[idx]
  else return EUCLID_DRUM_LOOPS[idx-24] end
end
local function get_bass_loop(idx)
  if idx <= 24 then return BASS_LOOPS[idx]
  else return EUCLID_BASS_LOOPS[idx-24] end
end
local TOTAL_DRUM = 36
local TOTAL_BASS = 36

-- ─────────────────────────────────────────────
-- MIDI
-- ─────────────────────────────────────────────
local function midi_note_on(ch, note, vel)
  if midi_out then midi_out:note_on(note, vel, ch) end
  opxy_note_on(note, vel)
end
local function midi_note_off(ch, note)
  if midi_out then midi_out:note_off(note, 0, ch) end
  opxy_note_off(note)
end
local function midi_all_notes_off(ch)
  if midi_out then
    midi_out:cc(123, 0, ch)
  end
  if opxy_out then opxy_out:cc(123, 0, params:get("opxy_channel")) end
end

-- ─────────────────────────────────────────────
-- HELPERS
-- ─────────────────────────────────────────────
local function valid_cell(c)
  return type(c)=="table" and type(c[1])=="number" and type(c[2])=="number"
end

local function humanize_vel(vel)
  local amt = params:get("humanize")*0.12
  return math.floor(util.clamp(vel+math.random(-1,1)*vel*amt, 1, 127))
end
local function humanize_delay()
  local amt = params:get("humanize")
  return amt>0 and (math.random()*amt*0.006) or 0
end
local function swing_delay(step)
  local sw = params:get("swing")
  if sw==50 or step%2~=0 then return 0 end
  return ((sw-50)/50.0)*(60/state.bpm/4)*0.33
end

local function get_step(get_loop_fn, pat_a, pat_b, morph_pos, step_idx, len_mult)
  local loop_a = get_loop_fn(pat_a)
  local eff_steps = math.max(1, math.floor(loop_a.steps * len_mult))
  local si_a = ((step_idx-1) % eff_steps) + 1
  -- map back into actual data range
  local data_i_a = math.min(si_a, loop_a.steps)
  local cell_a = loop_a.data[data_i_a]
  if not valid_cell(cell_a) then cell_a=nil end
  if not pat_b or morph_pos==0 then return cell_a end
  local loop_b = get_loop_fn(pat_b)
  local eff_b = math.max(1, math.floor(loop_b.steps * len_mult))
  local si_b = ((step_idx-1) % eff_b) + 1
  local data_i_b = math.min(si_b, loop_b.steps)
  local cell_b = loop_b.data[data_i_b]
  if not valid_cell(cell_b) then cell_b=nil end
  return (math.random()<morph_pos) and cell_b or cell_a
end

-- ─────────────────────────────────────────────
-- PATTERN MUTATION
-- randomly adds, removes, or shifts one hit
-- ─────────────────────────────────────────────
local function mutate_pattern(loop)
  local new_data = {}
  for i=1,loop.steps do
    new_data[i] = loop.data[i]
  end
  local action = math.random(3)
  if action == 1 then
    -- add a hit at a random empty step
    local empty = {}
    for i=1,loop.steps do
      if not valid_cell(new_data[i]) then table.insert(empty, i) end
    end
    if #empty > 0 then
      local pos = empty[math.random(#empty)]
      -- copy a random existing hit's note
      local hits = {}
      for i=1,loop.steps do
        if valid_cell(new_data[i]) then table.insert(hits, new_data[i]) end
      end
      if #hits > 0 then
        local src = hits[math.random(#hits)]
        new_data[pos] = {src[1], math.random(60,120)}
      end
    end
  elseif action == 2 then
    -- remove a random hit
    local filled = {}
    for i=1,loop.steps do
      if valid_cell(new_data[i]) then table.insert(filled, i) end
    end
    if #filled > 1 then
      new_data[filled[math.random(#filled)]] = nil
    end
  else
    -- shift a random hit one step forward or back
    local filled = {}
    for i=1,loop.steps do
      if valid_cell(new_data[i]) then table.insert(filled, i) end
    end
    if #filled > 0 then
      local src = filled[math.random(#filled)]
      local dir = math.random(2)==1 and 1 or -1
      local dst = ((src-1+dir) % loop.steps) + 1
      if not valid_cell(new_data[dst]) then
        new_data[dst] = new_data[src]
        new_data[src] = nil
      end
    end
  end
  return {steps=loop.steps, data=new_data}
end

-- mutation storage (overrides base patterns when set)
local drum_mutations = {}
local bass_mutations = {}

local function get_drum_loop_maybe_mutated(idx)
  return drum_mutations[idx] or get_drum_loop(idx)
end
local function get_bass_loop_maybe_mutated(idx)
  return bass_mutations[idx] or get_bass_loop(idx)
end

-- ─────────────────────────────────────────────
-- SCREEN
-- ─────────────────────────────────────────────
local function draw_mini(x, y, loop, active_step, morph_target, morph_pos, len_mult)
  local eff  = math.max(1, math.floor(loop.steps*len_mult))
  local vis  = math.min(eff, 16)
  local w    = math.max(1, math.floor(60/vis)-1)
  for i=1,vis do
    local px    = x+(i-1)*(w+1)
    local di    = math.min(i, loop.steps)
    local cell  = loop.data[di]
    local is_a  = (((active_step-1)%eff)+1==i)
    local lvl
    if is_a then lvl=15
    elseif valid_cell(cell) then
      lvl = morph_target and math.floor(8*(1-morph_pos)+3) or 8
    else lvl=2 end
    screen.level(lvl)
    screen.rect(px, y, w, 6)
    screen.fill()
  end
end

local function draw_vu(x, y, w, h, level)
  screen.level(2) screen.rect(x,y,w,h) screen.fill()
  local fw = math.floor(level*w)
  if fw>0 then
    screen.level(level>0.7 and 15 or level>0.4 and 10 or 6)
    screen.rect(x,y,fw,h) screen.fill()
  end
end

local function mult_str(m)
  if m==0.5 then return "/2" elseif m==2 then return "x2" else return "" end
end

local function screen_redraw()
  screen.clear()
  screen.level(3)
  screen.move(64,0) screen.line(64,64) screen.stroke()

  -- DRUMS
  screen.font_size(8)
  screen.move(4,8)
  local dlabel = "DRUMS"
  if state.drum_muted then dlabel=dlabel.."[M]" end
  if state.stutter_drum then dlabel=dlabel.."[S]" end
  if knob_loop.recording then dlabel=dlabel.."[REC]" end
  if knob_loop.playing then dlabel=dlabel.."[LOOP]" end
  screen.level(state.drum_muted and 4 or 15) screen.text(dlabel)
  screen.level(5) screen.font_size(7)
  screen.move(4,16)
  local dptn = state.drum_morph_target
    and (state.drum_pattern.."->"..state.drum_morph_target)
    or ("ptn "..state.drum_pattern..mult_str(state.drum_len_mult))
  screen.text(dptn)
  draw_mini(2,21,get_drum_loop_maybe_mutated(state.drum_pattern),
    state.drum_step, state.drum_morph_target, state.morph_pos, state.drum_len_mult)
  draw_vu(2,30,58,3,state.drum_level)
  screen.level(6) screen.font_size(7) screen.move(4,42) screen.text("BPM")
  screen.level(15) screen.font_size(16) screen.move(4,56) screen.text(tostring(state.bpm))
  screen.level(state.playing and 12 or 4) screen.font_size(7)
  screen.move(38,56) screen.text(state.playing and ">" or "=")

  -- ACID
  screen.font_size(8)
  screen.move(68,8)
  local blabel = "ACID"
  if state.bass_muted then blabel=blabel.."[M]" end
  if state.stutter_bass then blabel=blabel.."[S]" end
  if robot.active then blabel=blabel.."[ROBOT:"..robot.styles[robot.style_idx].."]"
  elseif knob_loop.playing then blabel=blabel.."[LOOP]" end
  screen.level(state.bass_muted and 4 or 15) screen.text(blabel)
  screen.level(5) screen.font_size(7)
  screen.move(68,16)
  local bptn = state.bass_morph_target
    and (state.bass_pattern.."->"..state.bass_morph_target)
    or ("ptn "..state.bass_pattern..mult_str(state.bass_len_mult))
  screen.text(bptn)
  draw_mini(66,21,get_bass_loop_maybe_mutated(state.bass_pattern),
    state.bass_step, state.bass_morph_target, state.morph_pos, state.bass_len_mult)
  draw_vu(66,30,58,3,state.bass_level)
  screen.level(6) screen.font_size(7) screen.move(68,42) screen.text("NOTE")
  screen.level(15) screen.font_size(16) screen.move(68,56)
  screen.text(state.active_bass_note and note_name(state.active_bass_note) or "--")

  if state.drum_morph_target or state.bass_morph_target then
    screen.level(3) screen.rect(0,62,128,2) screen.fill()
    screen.level(12) screen.rect(0,62,math.floor(state.morph_pos*128),2) screen.fill()
  end

  screen.update()
end

-- ─────────────────────────────────────────────
-- GRID
-- ─────────────────────────────────────────────
local function grid_redraw()
  if not grid_device then return end
  grid_device:all(0)

  -- rows 1-3: patterns (cols 1-8 drums, 9-16 bass)
  -- first 3 rows = patterns 1-24 hand-crafted
  for i=1,24 do
    local r=math.ceil(i/8) local c=((i-1)%8)+1
    grid_device:led(c,r,
      i==state.drum_pattern and 15 or
      i==state.drum_morph_target and 8 or
      drum_mutations[i] and 5 or 2)
  end
  for i=1,24 do
    local r=math.ceil(i/8) local c=((i-1)%8)+9
    grid_device:led(c,r,
      i==state.bass_pattern and 15 or
      i==state.bass_morph_target and 8 or
      bass_mutations[i] and 5 or 2)
  end

  -- row 4: playheads
  local dl = get_drum_loop_maybe_mutated(state.drum_pattern)
  local bl = get_bass_loop_maybe_mutated(state.bass_pattern)
  local de = math.max(1,math.floor(dl.steps*state.drum_len_mult))
  local be = math.max(1,math.floor(bl.steps*state.bass_len_mult))
  local ds = ((state.drum_step-1)%math.min(de,8))+1
  local bs = ((state.bass_step-1)%math.min(be,8))+1
  for i=1,8 do grid_device:led(i,  4, i==ds and 12 or 1) end
  for i=1,8 do grid_device:led(i+8,4, i==bs and 12 or 1) end

  -- row 5: divider
  for c=1,16 do grid_device:led(c,5,(c==8 or c==9) and 4 or 1) end

  -- row 6: morph scrub
  local mc=math.floor(state.morph_pos*15)+1
  for c=1,16 do grid_device:led(c,6,c==mc and 12 or 2) end

  -- row 7: mute + stutter
  -- left half: col1-4=mute drums, col5-8=stutter drums
  -- right half: col9-12=mute bass, col13-16=stutter bass
  for c=1,4  do grid_device:led(c,  7, state.drum_muted  and 15 or 3) end
  for c=5,8  do grid_device:led(c,  7, state.stutter_drum and 12 or 2) end
  for c=9,12 do grid_device:led(c,  7, state.bass_muted  and 15 or 3) end
  for c=13,16 do grid_device:led(c, 7, state.stutter_bass and 12 or 2) end

  -- row 8: save slots
  for c=1,16 do
    local bright
    if row8_hold[c] then
      local pct=math.min(1.0,(os.clock()-row8_hold[c].time)/HOLD_TIME)
      bright=math.floor(2+pct*13)
    elseif slots[c] then bright=8
    else bright=2 end
    grid_device:led(c,8,bright)
  end

  grid_device:refresh()
end

-- ─────────────────────────────────────────────
-- TICK
-- ─────────────────────────────────────────────
local active_bass_note_midi = nil

local function fire_drum(note, vel, extra_delay)
  local s = DRUM_SOUND[note]
  if not s then return end
  local density = params:get("drum_density")/100.0
  local amp = (vel/127)*s.amp*density
  clock.run(function()
    local d=extra_delay+humanize_delay()+swing_delay(state.drum_step)
    if d>0 then clock.sleep(d) end
    eng.set_release(s.release)
    eng.set_cutoff(s.cutoff)
    eng.set_amp(amp)
    eng.note_on(note, vel)
    state.drum_level=math.min(1,amp*1.3)
  end)
end

local function fire_bass(note, vel, extra_delay)
  local amp    = (vel/127)*0.82
  local cutoff = params:get("bass_cutoff")*(0.5+(vel/127)*0.5)
  local porto  = params:get("portamento")
  clock.run(function()
    local d=extra_delay+humanize_delay()
    if d>0 then clock.sleep(d) end
    eng.set_release(params:get("bass_release"))
    eng.set_cutoff(cutoff)
    eng.set_amp(amp)
    -- portamento: slide from last hz
    local target_hz = midi_to_hz(note)
    if porto>0 and state.last_bass_hz then
      local steps = math.floor(porto*20)
      local start_hz = state.last_bass_hz
      for i=1,steps do
        local t = i/steps
        local hz = start_hz + (target_hz-start_hz)*t
        eng.note_on(note, vel)
        clock.sleep(porto/steps)
      end
    end
    eng.note_on(note, vel)
    state.last_bass_hz = target_hz
    state.bass_level=math.min(1,amp*1.3)
  end)
end

-- probability gate: returns true if step should fire
local function prob_gate(step_idx)
  local prob = params:get("step_prob")
  if prob >= 100 then return true end
  return math.random(100) <= prob
end

local function tick()
  -- stutter: freeze step counter
  local d_step = state.drum_step
  local b_step = state.bass_step
  if state.stutter_drum then
    d_step = state.stutter_step
  end
  if state.stutter_bass then
    b_step = state.stutter_step
  end

  -- drums
  local d_cell = get_step(get_drum_loop_maybe_mutated,
    state.drum_pattern, state.drum_morph_target,
    state.morph_pos, d_step, state.drum_len_mult)
  local drum_fired = false
  if d_cell and not state.drum_muted and prob_gate(d_step) then
    local note,vel = d_cell[1], humanize_vel(d_cell[2])
    fire_drum(note, vel, 0)
    midi_note_on(drum_midi_ch, note, vel)
    clock.run(function() clock.sleep(0.05) midi_note_off(drum_midi_ch,note) end)
    drum_fired = true
  else
    state.drum_level=state.drum_level*0.5
  end
  if not state.stutter_drum then state.drum_step=state.drum_step+1 end

  -- bass (12ms offset)
  local b_cell = get_step(get_bass_loop_maybe_mutated,
    state.bass_pattern, state.bass_morph_target,
    state.morph_pos, b_step, state.bass_len_mult)
  if active_bass_note_midi then
    midi_note_off(bass_midi_ch, active_bass_note_midi)
    active_bass_note_midi=nil
  end
  if b_cell and not state.bass_muted and prob_gate(b_step) then
    local note,vel = b_cell[1], humanize_vel(b_cell[2])
    fire_bass(note, vel, 0.012)
    midi_note_on(bass_midi_ch, note, vel)
    active_bass_note_midi   = note
    state.active_bass_note  = note
  else
    state.bass_level=state.bass_level*0.6
    state.active_bass_note=nil
  end
  if not state.stutter_bass then state.bass_step=state.bass_step+1 end

  -- stutter step cycles through a short window
  if state.stutter_drum or state.stutter_bass then
    state.stutter_step = state.stutter_step + 1
    if state.stutter_step > 4 then state.stutter_step = 1 end
  end

  dirty=true
  grid_redraw()
end

-- ─────────────────────────────────────────────
-- KNOB LOOPER
-- ─────────────────────────────────────────────
local function knob_loop_start_recording()
  knob_loop.recording = true
  knob_loop.playing = false
  knob_loop.data.enc2 = {}
  knob_loop.data.enc3 = {}
  knob_loop.start_beat = clock.get_beats()
  knob_loop.rec_activity = 1.0
  print("50/50: recording encoder movements...")
end

local function knob_loop_stop_recording()
  knob_loop.recording = false
  -- quantize to nearest bar (4 beats)
  local raw_beats = knob_loop.playhead
  local quantized = math.max(4, math.floor((raw_beats+2)/4)*4)
  knob_loop.loop_length = quantized
  -- reset playhead for playback
  knob_loop.playhead = 0
  print("50/50: recorded loop length = "..knob_loop.loop_length.." beats")
end

local function knob_loop_toggle_playback()
  if knob_loop.loop_length == 0 then
    print("50/50: no loop recorded")
    return
  end
  knob_loop.playing = not knob_loop.playing
  if knob_loop.playing then
    knob_loop.playhead = 0
    print("50/50: loop playing")
  else
    print("50/50: loop stopped")
  end
end

local function knob_loop_tick(current_beat)
  if not knob_loop.recording and not knob_loop.playing then return end
  
  if knob_loop.recording then
    knob_loop.playhead = current_beat - knob_loop.start_beat
    knob_loop.rec_activity = math.max(0, knob_loop.rec_activity - 0.01)
  end
  
  if knob_loop.playing then
    knob_loop.playhead = knob_loop.playhead + (1/96)  -- tick resolution
    if knob_loop.playhead >= knob_loop.loop_length then
      knob_loop.playhead = 0
    end
    
    -- replay recorded events
    for _,event in ipairs(knob_loop.data.enc2) do
      local beat_pos, delta = event[1], event[2]
      if math.abs(knob_loop.playhead - beat_pos) < 0.01 then
        state.drum_pattern = util.clamp(state.drum_pattern + delta, 1, TOTAL_DRUM)
      end
    end
    for _,event in ipairs(knob_loop.data.enc3) do
      local beat_pos, delta = event[1], event[2]
      if math.abs(knob_loop.playhead - beat_pos) < 0.01 then
        state.bass_pattern = util.clamp(state.bass_pattern + delta, 1, TOTAL_BASS)
      end
    end
  end
end

-- ─────────────────────────────────────────────
-- ROBOT MODE
-- ─────────────────────────────────────────────
local function robot_cycle_style()
  robot.style_idx = robot.style_idx + 1
  if robot.style_idx > #robot.styles then robot.style_idx = 1 end
  robot.active = (robot.style_idx > 1)
  if robot.active then
    robot.phase = 0
    local style = robot.styles[robot.style_idx]
    if style == "breathe" then robot.cycle_length = 32
    elseif style == "build" then robot.cycle_length = 16 robot.build_direction = 1
    elseif style == "chaos" then robot.cycle_length = 8
    elseif style == "pocket" then robot.cycle_length = 16 end
    print("50/50: Robot Mode = "..style)
  else
    print("50/50: Robot Mode off")
  end
end

local function robot_tick(current_beat)
  if not robot.active then return end
  
  local style = robot.styles[robot.style_idx]
  robot.phase = (current_beat % (robot.cycle_length * 4)) / (robot.cycle_length * 4)
  local t = robot.phase
  
  if style == "breathe" then
    -- slow sine wave on both encoders
    local sine2 = 64 + 32 * math.sin(t * math.pi * 2)
    local sine3 = 64 + 32 * math.sin((t + 0.25) * math.pi * 2)
    robot.enc2_pos = sine2
    robot.enc3_pos = sine3
  elseif style == "build" then
    -- gradually increase, then reset
    if t < 0.8 then
      robot.enc2_pos = 32 + 64 * t
      robot.enc3_pos = 32 + 64 * t
    else
      robot.enc2_pos = 32 + 64 * math.sin(t * math.pi)
      robot.enc3_pos = 32 + 64 * math.cos(t * math.pi)
    end
  elseif style == "chaos" then
    -- rapid random movements
    robot.random_counter = robot.random_counter + 1
    if robot.random_counter > 2 then
      robot.random_counter = 0
      robot.enc2_pos = 32 + math.random() * 64
      robot.enc3_pos = 32 + math.random() * 64
    end
  elseif style == "pocket" then
    -- small rhythmic movements, synced to beat (half-step)
    local beat_frac = (current_beat % 0.5) / 0.5
    robot.enc2_pos = 64 + 12 * math.sin(beat_frac * math.pi * 2)
    robot.enc3_pos = 64 + 12 * math.cos(beat_frac * math.pi * 2)
  end
end

-- ─────────────────────────────────────────────
-- CLOCKS
-- ─────────────────────────────────────────────
local function start_clock()
  if clock_id then clock.cancel(clock_id) end
  clock_id = clock.run(function()
    while true do
      clock.sync(1/4)
      tick()
    end
  end)
end

local function start_morph_clock()
  if morph_clock_id then clock.cancel(morph_clock_id) end
  morph_clock_id = clock.run(function()
    while true do
      clock.sleep(1/30)
      if state.drum_morph_target or state.bass_morph_target then
        state.morph_pos=state.morph_pos+params:get("morph_speed")
        if state.morph_pos>=1.0 then
          state.morph_pos=0.0
          if state.drum_morph_target then
            state.drum_pattern=state.drum_morph_target
            state.drum_morph_target=nil
            state.drum_step=1
          end
          if state.bass_morph_target then
            state.bass_pattern=state.bass_morph_target
            state.bass_morph_target=nil
            state.bass_step=1
          end
        end
      end
    end
  end)
end

local function start_robot_clock()
  if robot_clock_id then clock.cancel(robot_clock_id) end
  robot_clock_id = clock.run(function()
    while true do
      clock.sync(1/96)
      if state.playing then
        local current_beat = clock.get_beats()
        robot_tick(current_beat)
        knob_loop_tick(current_beat)
        dirty=true
      end
    end
  end)
end

-- ─────────────────────────────────────────────
-- BANDMATE: auto-twist E2/E3 + filter on tempo
-- ─────────────────────────────────────────────
local function bandmate_tick()
  while true do
    clock.sync(1)
    if not bandmate.active or not state.playing then goto skip end
    bandmate.phase = bandmate.phase + 1

    -- "Turn E2" — step through drum patterns (like slowly turning encoder)
    if bandmate.phase % 2 == 0 then
      local dir = math.sin(bandmate.phase * 0.03) > 0 and 1 or -1
      state.drum_pattern = util.clamp(state.drum_pattern + dir, 1, TOTAL_DRUM)
      state.drum_step = 1
    end

    -- "Turn E3" — step through bass patterns (offset phase)
    if bandmate.phase % 3 == 0 then
      local dir = math.cos(bandmate.phase * 0.05) > 0 and 1 or -1
      state.bass_pattern = util.clamp(state.bass_pattern + dir, 1, TOTAL_BASS)
      state.bass_step = 1
    end

    -- Sweep bass_cutoff with sine LFO
    local cutoff_lfo = math.sin(bandmate.phase * bandmate.cutoff_lfo_speed) * 0.5 + 0.5
    params:set("bass_cutoff", 200 + cutoff_lfo * 4800)

    -- Subtle swing drift
    local swing_lfo = math.sin(bandmate.phase * bandmate.swing_lfo_speed) * 0.5 + 0.5
    params:set("swing", 40 + swing_lfo * 30)

    dirty = true; grid_dirty = true
    ::skip::
  end
end

-- ─────────────────────────────────────────────
-- TAP TEMPO
-- ─────────────────────────────────────────────
local function tap_tempo()
  local now = os.clock()
  if now - state.last_tap > 2.0 then
    state.tap_times = {}
    state.tap_count = 0
  end
  state.last_tap = now
  state.tap_count = state.tap_count + 1
  table.insert(state.tap_times, now)
  if #state.tap_times > 8 then table.remove(state.tap_times, 1) end
  if #state.tap_times >= 2 then
    local sum = 0
    for i=2,#state.tap_times do
      sum = sum + (state.tap_times[i] - state.tap_times[i-1])
    end
    local avg = sum / (#state.tap_times-1)
    local new_bpm = math.floor(util.clamp(60/avg, 40, 300))
    state.bpm = new_bpm
    params:set("clock_tempo", state.bpm)
    dirty=true
  end
end

-- ─────────────────────────────────────────────
-- GRID KEY
-- ─────────────────────────────────────────────
local function grid_key(x, y, z)
  -- row 8: save slots
  if y == 8 then
    if z == 1 then
      row8_hold[x]={time=os.clock(), saved=false}
      local sx=x
      clock.run(function()
        clock.sleep(HOLD_TIME)
        if row8_hold[sx] and not row8_hold[sx].saved then
          slots[sx]={drum=state.drum_pattern, bass=state.bass_pattern}
          row8_hold[sx].saved=true
          if grid_device then
            grid_device:led(sx,8,15) grid_device:refresh()
          end
          clock.sleep(0.2)
          grid_redraw()
          print("50/50: saved slot "..sx)
        end
      end)
      clock.run(function()
        while row8_hold[sx]~=nil do
          clock.sleep(0.05) grid_redraw()
        end
      end)
    else
      if row8_hold[x] then
        local was_saved=row8_hold[x].saved
        row8_hold[x]=nil
        if not was_saved and slots[x] then
          if state.playing then
            state.drum_morph_target=slots[x].drum
            state.bass_morph_target=slots[x].bass
          else
            state.drum_pattern=slots[x].drum
            state.bass_pattern=slots[x].bass
            state.drum_step=1 state.bass_step=1
          end
          print("50/50: recalled slot "..x)
        end
      end
    end
    dirty=true; grid_dirty=true
    return
  end

  if z == 1 then
    if y <= 3 then
      if x <= 8 then
        local idx=(y-1)*8+x
        if idx>=1 and idx<=TOTAL_DRUM then
          if idx==state.drum_pattern then
            state.drum_morph_target=nil state.morph_pos=0
          elseif state.playing then
            state.drum_morph_target=idx
          else
            state.drum_pattern=idx state.drum_step=1
          end
        end
      else
        local idx=(y-1)*8+(x-8)
        if idx>=1 and idx<=TOTAL_BASS then
          if idx==state.bass_pattern then
            state.bass_morph_target=nil state.morph_pos=0
          elseif state.playing then
            state.bass_morph_target=idx
          else
            state.bass_pattern=idx state.bass_step=1
          end
        end
      end
    elseif y == 6 then
      state.morph_pos=(x-1)/15
    elseif y == 7 then
      -- col 1-4: mute drums | col 5-8: stutter drums
      -- col 9-12: mute bass | col 13-16: stutter bass
      if x<=4 then
        state.drum_muted=not state.drum_muted
        if state.drum_muted then midi_all_notes_off(DRUM_CH) end
      elseif x<=8 then
        state.stutter_drum=not state.stutter_drum
        if state.stutter_drum then state.stutter_step=util.clamp(state.drum_step, 1, 4) end
      elseif x<=12 then
        state.bass_muted=not state.bass_muted
        if state.bass_muted and active_bass_note_midi then
          midi_note_off(BASS_CH,active_bass_note_midi)
          active_bass_note_midi=nil state.active_bass_note=nil
        end
      else
        state.stutter_bass=not state.stutter_bass
        if state.stutter_bass then state.stutter_step=util.clamp(state.bass_step, 1, 4) end
      end
    end
    dirty=true; grid_dirty=true
  end
end

-- ─────────────────────────────────────────────
-- KEYS & ENCODERS
-- ─────────────────────────────────────────────
-- K1 = system (norns reserved, not intercepted)
-- K2 tap = play/stop, K2 double-tap = tap tempo, K2 long-press = knob loop rec
-- K3 tap = randomize, K3 long-press = cycle robot mode
local k2_last_press = 0
local k2_tap_pending = false
local k2_press_time = 0
local k3_press_time = 0
local K_LONG_PRESS = 0.5  -- seconds for long-press threshold

function key(n, z)
  -- K1: reserved for norns system menu, do not intercept
  if n==1 then return end

  if n==2 then
    if z==1 then
      k2_press_time = os.clock()
    else
      -- K2 release: check long-press
      local held = os.clock() - k2_press_time
      if held >= K_LONG_PRESS then
        -- long-press K2: toggle knob loop recording
        if knob_loop.recording then
          knob_loop_stop_recording()
        else
          knob_loop_start_recording()
        end
        dirty=true; grid_dirty=true
        return
      end
      -- short press: double-tap for tempo, single tap for play/stop
      local now = os.clock()
      if now - k2_last_press < 0.4 then
        -- double tap = tap tempo
        tap_tempo()
        k2_tap_pending=false
      else
        k2_tap_pending=true
        clock.run(function()
          clock.sleep(0.4)
          if k2_tap_pending then
            -- single tap = play/stop
            k2_tap_pending=false
            state.playing=not state.playing
            if state.playing then
              state.drum_step=1 state.bass_step=1
              start_clock()
              knob_loop.playhead = 0
            else
              if clock_id then clock.cancel(clock_id) end
              if active_bass_note_midi then
                midi_note_off(BASS_CH,active_bass_note_midi)
                active_bass_note_midi=nil state.active_bass_note=nil
              end
            end
            dirty=true; grid_dirty=true
          end
        end)
      end
      k2_last_press=now
    end

  elseif n==3 then
    if z==1 then
      k3_press_time = os.clock()
    else
      -- K3 release: check long-press
      local held = os.clock() - k3_press_time
      if held >= K_LONG_PRESS then
        -- long-press K3: cycle robot mode
        robot_cycle_style()
        dirty=true; grid_dirty=true
        return
      end
      -- short press K3: randomize
      state.drum_pattern=math.random(1,TOTAL_DRUM)
      state.bass_pattern=math.random(1,TOTAL_BASS)
      state.drum_step=1 state.bass_step=1
      state.drum_morph_target=nil state.bass_morph_target=nil
      state.morph_pos=0
      dirty=true; grid_dirty=true
    end
  end
end

function enc(n, d)
  if n==1 then
    state.bpm=util.clamp(state.bpm+d, 40, 300)
    params:set("clock_tempo", state.bpm)
  elseif n==2 then
    -- record encoder movement if recording
    if knob_loop.recording then
      local beat_pos = clock.get_beats() - knob_loop.start_beat
      table.insert(knob_loop.data.enc2, {beat_pos, d})
      knob_loop.rec_activity = 1.0
    end
    state.drum_pattern=util.clamp(state.drum_pattern+d, 1, TOTAL_DRUM)
    state.drum_step=1
  elseif n==3 then
    -- record encoder movement if recording
    if knob_loop.recording then
      local beat_pos = clock.get_beats() - knob_loop.start_beat
      table.insert(knob_loop.data.enc3, {beat_pos, d})
      knob_loop.rec_activity = 1.0
    end
    state.bass_pattern=util.clamp(state.bass_pattern+d, 1, TOTAL_BASS)
    state.bass_step=1
  end
  dirty=true; grid_dirty=true
end

-- ─────────────────────────────────────────────
-- PARAMS
-- ─────────────────────────────────────────────
local function tab_index(tbl, val)
  for i, v in ipairs(tbl) do
    if v == val then return i end
  end
  return 1
end

local function add_params()
  params:add_separator("50/50")

  -- Engine selection
  params:add_option("engine_select", "sound engine", ENGINE_OPTIONS,
    tab_index(ENGINE_OPTIONS, current_engine))
  params:set_action("engine_select", function(val)
    local new_engine = ENGINE_OPTIONS[val]
    if new_engine ~= current_engine then
      save_engine_choice(new_engine)
      print("Switching engine to " .. new_engine .. " - reloading script...")
      norns.script.load(norns.state.script)
    end
  end)

  params:add_control("bass_cutoff","Bass Cutoff",
    controlspec.new(100,8000,"exp",1,900,"hz"))
  params:add_control("bass_release","Bass Release",
    controlspec.new(0.01,2.0,"exp",0.01,0.18,"s"))
  params:add_control("portamento","Portamento",
    controlspec.new(0,0.3,"lin",0.01,0,"s"))
  params:add_number("drum_density","Drum Density",10,100,100)
  params:add_number("step_prob","Step Probability",10,100,100)
  params:add_number("swing","Swing",0,100,50)
  params:add_number("humanize","Humanize",0,10,2)
  params:add_control("morph_speed","Morph Speed",
    controlspec.new(0.001,0.05,"lin",0.001,0.015,""))

  -- length multiplier per side
  params:add_option("drum_len_mult","Drum Length",{"1/2","1x","2x"},2)
  params:set_action("drum_len_mult",function(v)
    local mults={0.5,1,2}
    state.drum_len_mult=mults[v]
    state.drum_step=1
  end)
  params:add_option("bass_len_mult","Bass Length",{"1/2","1x","2x"},2)
  params:set_action("bass_len_mult",function(v)
    local mults={0.5,1,2}
    state.bass_len_mult=mults[v]
    state.bass_step=1
  end)

  -- mutation triggers
  params:add_trigger("mutate_drum","Mutate Drum Pattern")
  params:set_action("mutate_drum",function()
    local base=get_drum_loop(state.drum_pattern)
    drum_mutations[state.drum_pattern]=mutate_pattern(base)
    print("50/50: mutated drum "..state.drum_pattern)
  end)
  params:add_trigger("mutate_bass","Mutate Bass Pattern")
  params:set_action("mutate_bass",function()
    local base=get_bass_loop(state.bass_pattern)
    bass_mutations[state.bass_pattern]=mutate_pattern(base)
    print("50/50: mutated bass "..state.bass_pattern)
  end)
  params:add_trigger("clear_mutations","Clear All Mutations")
  params:set_action("clear_mutations",function()
    drum_mutations={} bass_mutations={}
    print("50/50: mutations cleared")
  end)

  -- Robot Mode energy
  params:add_control("robot_energy","Robot Energy",
    controlspec.new(0,1,"lin",0.05,0.5,""))
  params:set_action("robot_energy",function(v) robot.energy=v end)

  -- split position
  params:add_number("split_col","Split Position",4,12,8)
  params:set_action("split_col",function(v) split_col=v end)

  -- cross-side coupling
  params:add_control("coupling","Cross-Side Coupling",
    controlspec.new(0,1,"lin",0.01,0,""))
  params:set_action("coupling",function(v) coupling=v end)

  -- randomize intensity
  params:add_number("random_amount","Randomize Intensity",0,100,100)
  params:set_action("random_amount",function(v) random_amount=v end)

  -- per-side MIDI channels
  params:add_number("drum_midi_ch","Drum MIDI CH",1,16,10)
  params:set_action("drum_midi_ch",function(v) drum_midi_ch=v end)
  params:add_number("bass_midi_ch","Bass MIDI CH",1,16,1)
  params:set_action("bass_midi_ch",function(v) bass_midi_ch=v end)

  params:add_number("midi_out_device","MIDI Out Device",1,4,1)
  params:set_action("midi_out_device",function(v)
    midi_out=midi.connect(v)
  end)

  params:add_separator("OP-XY")
  params:add_number("opxy_device","OP-XY MIDI Device",1,4,2)
  params:set_action("opxy_device",function(v)
    opxy_out=midi.connect(v)
  end)
  params:add_number("opxy_channel","OP-XY MIDI Channel",1,16,1)

  -- BANDMATE
  params:add_separator("BANDMATE")
  params:add_option("bandmate_mode", "Bandmate", {"off", "on"}, 1)
  params:set_action("bandmate_mode", function(v)
    bandmate.active = (v == 2)
    if bandmate.active and not bandmate.clock_id then
      bandmate.phase = 0
      bandmate.clock_id = clock.run(bandmate_tick)
    end
    dirty = true
  end)

  -- PSET save/load is handled automatically by norns params system
  -- use PARAMS > PSET > SAVE to persist all settings
end

-- ─────────────────────────────────────────────
-- INIT
-- ─────────────────────────────────────────────
function init()
  math.randomseed(os.time())

  build_euclid_patterns()

  state.drum_pattern=math.random(1,TOTAL_DRUM)
  state.bass_pattern=math.random(1,TOTAL_BASS)
  state.bpm=128

  -- Setup engine abstraction
  setup_engine_interface()

  -- Engine-specific initialization
  if current_engine == "PolyPerc" then
    engine.gain(4.0)
    engine.cutoff(900)
    engine.release(0.15)
    engine.amp(0.8)
  elseif current_engine == "MollyThePoly" then
    local MollyThePoly = require "molly_the_poly/lib/molly_the_poly_engine"
    MollyThePoly.add_params()
    params:set("lp_filter_cutoff", 2000)
    params:set("lp_filter_resonance", 0.15)
    params:set("env_2_release", 0.5)
    params:set("amp", 0.7)
  elseif current_engine == "Supertonic" then
    -- Supertonic setup (minimal for now, params will be added by its lib)
  end

  add_params()

  midi_out=midi.connect(params:get("midi_out_device"))
  opxy_out=midi.connect(params:get("opxy_device"))

  local g=grid.connect()
  if g.device~=nil then
    grid_device=g
    grid_device.key=grid_key
  end

  params:set("clock_tempo", state.bpm)
  start_morph_clock()
  start_robot_clock()
  bandmate.clock_id = clock.run(bandmate_tick)

  -- Screen refresh at 15fps using dirty flag
  local redraw_metro = metro.init()
  redraw_metro.event = function()
    if dirty then
      dirty = false
      redraw()
    end
    if grid_dirty and grid_device then
      grid_dirty = false
      grid_redraw()
    end
  end
  redraw_metro:start(1/15)

  dirty = true
  grid_dirty = true

  print("50/50 v14 + Multi-Engine Ready")
  print("Current Engine: " .. current_engine)
  print("K1: System Menu | K2: Play/Stop | K3: Randomize")
  print("K2 double-tap: tap tempo | K2 long-press: knob loop rec")
  print("K3 long-press: cycle Robot Mode (breathe/build/chaos/pocket)")
  print("Change engine in PARAMS > sound engine (reloads script)")
end

function redraw()
  screen_redraw()
end

function cleanup()
  if clock_id       then clock.cancel(clock_id)       end
  if morph_clock_id then clock.cancel(morph_clock_id) end
  if robot_clock_id then clock.cancel(robot_clock_id) end
  if bandmate.clock_id then clock.cancel(bandmate.clock_id) end
  if active_bass_note_midi then midi_note_off(BASS_CH,active_bass_note_midi) end
  midi_all_notes_off(DRUM_CH)
  midi_all_notes_off(BASS_CH)
  if opxy_out then opxy_out:cc(123, 0, params:get("opxy_channel")) end
  eng.kill_all()
end