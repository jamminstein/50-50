-- 50/50 v14 + Multi-Engine Selection
-- drums + bass sequencer / PolyPerc, MollyThePoly, or Supertonic
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
--
-- NEW: K1+K2: record/stop encoder movements (Knob Looper)
-- NEW: K1+K3: cycle Robot Mode styles (breathe/build/chaos/pocket)
-- NEW: Multi-engine selection (PolyPerc / MollyThePoly / Supertonic)

-- ──────────────────────────────────────────────
-- ENGINE SELECTION (persisted to file)
-- ──────────────────────────────────────────────
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

-- ──────────────────────────────────────────────
-- ENGINE ABSTRACTION LAYER
-- ──────────────────────────────────────────────
local eng = {}

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
    eng.cutoff_set = function(val)
      engine.cutoff(val)
    end
    eng.resonance_set = function(val)
      engine.res(val)
    end
    eng.attack_set = function(val)
      engine.attack(val)
    end
    eng.decay_set = function(val)
      engine.decay(val)
    end
    eng.release_set = function(val)
      engine.release(val)
    end
    eng.pitch_bend = function(val)
      -- PolyPerc doesn't have native pitch bend, skip
    end

  elseif current_engine == "MollyThePoly" then
    -- MollyThePoly: note_on/note_off with velocity
    eng.note_on = function(note, vel)
      engine.note_on(note, math.floor(vel * 127))
    end
    eng.note_off = function(note)
      engine.note_off(note)
    end
    eng.cutoff_set = function(val)
      engine.cutoff(val)
    end
    eng.resonance_set = function(val)
      engine.resonance(val)
    end
    eng.attack_set = function(val)
      engine.attack(val)
    end
    eng.decay_set = function(val)
      engine.decay(val)
    end
    eng.release_set = function(val)
      engine.release(val)
    end
    eng.pitch_bend = function(val)
      engine.pitchbend(val)
    end

  elseif current_engine == "Supertonic" then
    -- Supertonic: note_on/note_off with velocity, includes tremolo
    eng.note_on = function(note, vel)
      engine.note_on(note, math.floor(vel * 127))
    end
    eng.note_off = function(note)
      engine.note_off(note)
    end
    eng.cutoff_set = function(val)
      engine.cutoff(val)
    end
    eng.resonance_set = function(val)
      engine.resonance(val)
    end
    eng.attack_set = function(val)
      engine.attack(val)
    end
    eng.decay_set = function(val)
      engine.decay(val)
    end
    eng.release_set = function(val)
      engine.release(val)
    end
    eng.pitch_bend = function(val)
      engine.pitchbend(val)
    end
  end
end

setup_engine_interface()

-- ──────────────────────────────────────────────
-- STATE
-- ──────────────────────────────────────────────
local drum_active = true
local bass_active = true

local bpm = 120
local bpm_display = "120"
local clock_div = 1  -- for tap tempo
local clock_count = 0
local tick_count = 0

local tap_tempo_state = "off"  -- off, waiting, running
local tap_times = {}
local tap_last_time = 0
local tap_double_tap_window = 0.5  -- seconds

-- Drum state
local drum_patterns = {}
local drum_playing = {1, 1, 1}  -- which drum pattern is "playing" per beat
local drum_pattern_idx = 1  -- which pattern user is editing
local drum_pattern_names = {"Kick", "Snare", "Hat"}
local drum_sequence_len = 16

for i = 1, 3 do
  drum_patterns[i] = {}
  for j = 1, drum_sequence_len do
    drum_patterns[i][j] = false
  end
end

-- Bass state
local bass_patterns = {}
local bass_playing = {1}  -- which bass pattern is "playing" per beat
local bass_pattern_idx = 1
local bass_sequence_len = 16
local bass_octave = 3
local bass_octave_display = "3"

for i = 1, 3 do
  bass_patterns[i] = {}
  for j = 1, bass_sequence_len do
    bass_patterns[i][j] = 60  -- middle C
  end
end

local playhead_drums = 1
local playhead_bass = 1
local divider_val = 1  -- 1=16th, 2=8th, 4=quarter

-- Grid/Morph parameters
local morph_scrub_pos = 0.5
local morph_scrub_active = false

-- Drum parameters
local drum_params = {
  cutoff = 5000,
  resonance = 0.8,
  attack = 0.001,
  decay = 0.3,
  release = 0.1
}

-- Bass parameters
local bass_params = {
  cutoff = 2000,
  resonance = 0.5,
  attack = 0.01,
  decay = 0.2,
  release = 0.3
}

-- Knob looper (record encoder movements)
local knob_looper = {
  recording = false,
  playback = false,
  movements = {}  -- {time, enc, delta}
}

-- Robot mode
local robot_mode = {
  enabled = false,
  style = "breathe",  -- breathe, build, chaos, pocket
  time = 0,
  cycle_duration = 4  -- beats
}

-- Save slots
local save_slots = {}
for i = 1, 16 do
  save_slots[i] = nil
end

local save_slot_hold_time = {}
local save_slot_hold_threshold = 3  -- seconds to save

-- ──────────────────────────────────────────────
-- UTILITIES
-- ──────────────────────────────────────────────

local function constrain(v, min, max)
  return math.max(min, math.min(max, v))
end

local function scale(v, min_in, max_in, min_out, max_out)
  return min_out + (v - min_in) * (max_out - min_out) / (max_in - min_in)
end

local function save_state()
  local path = _path.data .. "50-50/state.txt"
  util.make_dir(_path.data .. "50-50/")
  local f = io.open(path, "w")
  if f then
    f:write("bpm:" .. bpm .. "\n")
    f:write("drum_pattern_idx:" .. drum_pattern_idx .. "\n")
    f:write("bass_pattern_idx:" .. bass_pattern_idx .. "\n")
    f:write("bass_octave:" .. bass_octave .. "\n")
    f:write("divider_val:" .. divider_val .. "\n")
    f:write("drum_cutoff:" .. drum_params.cutoff .. "\n")
    f:write("drum_resonance:" .. drum_params.resonance .. "\n")
    f:write("drum_attack:" .. drum_params.attack .. "\n")
    f:write("drum_decay:" .. drum_params.decay .. "\n")
    f:write("drum_release:" .. drum_params.release .. "\n")
    f:write("bass_cutoff:" .. bass_params.cutoff .. "\n")
    f:write("bass_resonance:" .. bass_params.resonance .. "\n")
    f:write("bass_attack:" .. bass_params.attack .. "\n")
    f:write("bass_decay:" .. bass_params.decay .. "\n")
    f:write("bass_release:" .. bass_params.release .. "\n")
    f:close()
  end
end

local function load_state()
  local path = _path.data .. "50-50/state.txt"
  local f = io.open(path, "r")
  if f then
    for line in f:lines() do
      local key, val = line:match("([^:]+):(.+)")
      if key and val then
        val = tonumber(val) or val
        if key == "bpm" then bpm = val end
        if key == "drum_pattern_idx" then drum_pattern_idx = val end
        if key == "bass_pattern_idx" then bass_pattern_idx = val end
        if key == "bass_octave" then bass_octave = val end
        if key == "divider_val" then divider_val = val end
        if key == "drum_cutoff" then drum_params.cutoff = val end
        if key == "drum_resonance" then drum_params.resonance = val end
        if key == "drum_attack" then drum_params.attack = val end
        if key == "drum_decay" then drum_params.decay = val end
        if key == "drum_release" then drum_params.release = val end
        if key == "bass_cutoff" then bass_params.cutoff = val end
        if key == "bass_resonance" then bass_params.resonance = val end
        if key == "bass_attack" then bass_params.attack = val end
        if key == "bass_decay" then bass_params.decay = val end
        if key == "bass_release" then bass_params.release = val end
      end
    end
    f:close()
  end
end

local function table_to_string(t)
  local result = ""
  for i, v in ipairs(t) do
    if v then result = result .. "1" else result = result .. "0" end
  end
  return result
end

local function string_to_table(s)
  local t = {}
  for i = 1, #s do
    local char = s:sub(i, i)
    t[i] = (char == "1")
  end
  return t
end

local function save_slot_save(slot_idx)
  local slot = {
    drum_patterns = {},
    bass_patterns = {},
    drum_pattern_idx = drum_pattern_idx,
    bass_pattern_idx = bass_pattern_idx,
    bpm = bpm,
    bass_octave = bass_octave,
    divider_val = divider_val,
    drum_params = {cutoff = drum_params.cutoff, resonance = drum_params.resonance, attack = drum_params.attack, decay = drum_params.decay, release = drum_params.release},
    bass_params = {cutoff = bass_params.cutoff, resonance = bass_params.resonance, attack = bass_params.attack, decay = bass_params.decay, release = bass_params.release}
  }
  for i = 1, 3 do
    slot.drum_patterns[i] = table_to_string(drum_patterns[i])
  end
  for i = 1, 3 do
    slot.bass_patterns[i] = table_to_string(bass_patterns[i])
  end
  save_slots[slot_idx] = slot
end

local function save_slot_load(slot_idx)
  if save_slots[slot_idx] == nil then return end
  local slot = save_slots[slot_idx]
  
  drum_pattern_idx = slot.drum_pattern_idx or 1
  bass_pattern_idx = slot.bass_pattern_idx or 1
  bpm = slot.bpm or 120
  bass_octave = slot.bass_octave or 3
  divider_val = slot.divider_val or 1
  
  drum_params.cutoff = slot.drum_params.cutoff or 5000
  drum_params.resonance = slot.drum_params.resonance or 0.8
  drum_params.attack = slot.drum_params.attack or 0.001
  drum_params.decay = slot.drum_params.decay or 0.3
  drum_params.release = slot.drum_params.release or 0.1
  
  bass_params.cutoff = slot.bass_params.cutoff or 2000
  bass_params.resonance = slot.bass_params.resonance or 0.5
  bass_params.attack = slot.bass_params.attack or 0.01
  bass_params.decay = slot.bass_params.decay or 0.2
  bass_params.release = slot.bass_params.release or 0.3
  
  for i = 1, 3 do
    if slot.drum_patterns[i] then
      drum_patterns[i] = string_to_table(slot.drum_patterns[i])
    end
  end
  for i = 1, 3 do
    if slot.bass_patterns[i] then
      bass_patterns[i] = string_to_table(slot.bass_patterns[i])
    end
  end
end

-- ──────────────────────────────────────────────
-- PLAYBACK
-- ──────────────────────────────────────────────

local function play_drum(pattern_idx, step, vel)
  if drum_patterns[pattern_idx] and drum_patterns[pattern_idx][step] then
    local note = 60 + (pattern_idx - 1) * 2  -- spread across octave
    eng.note_on(note, vel)
    -- No note_off for PolyPerc; decay handles it
  end
end

local function play_bass(pattern_idx, step, vel)
  if bass_patterns[pattern_idx] and bass_patterns[pattern_idx][step] then
    local note = bass_patterns[pattern_idx][step] + (bass_octave * 12)
    eng.note_on(note, vel)
  end
end

local function apply_params()
  eng.cutoff_set(drum_params.cutoff)
  eng.resonance_set(drum_params.resonance)
  eng.attack_set(drum_params.attack)
  eng.decay_set(drum_params.decay)
  eng.release_set(drum_params.release)
end

-- ──────────────────────────────────────────────
-- CLOCK
-- ──────────────────────────────────────────────

local function clock_tick()
  tick_count = tick_count + 1
  local ticks_per_beat = 4  -- assuming 24 ppq
  if tick_count >= ticks_per_beat then
    tick_count = 0
    clock_count = clock_count + 1

    -- Update robot mode if enabled
    if robot_mode.enabled then
      robot_mode.time = robot_mode.time + 1
      if robot_mode.time >= robot_mode.cycle_duration * 4 then
        robot_mode.time = 0
      end
    end

    -- Playhead advance (gated by divider)
    if clock_count % divider_val == 0 then
      playhead_drums = (playhead_drums % drum_sequence_len) + 1
      playhead_bass = (playhead_bass % bass_sequence_len) + 1
    end

    -- Play notes on playhead
    if drum_active and drum_patterns[drum_pattern_idx] and drum_patterns[drum_pattern_idx][playhead_drums] then
      play_drum(drum_pattern_idx, playhead_drums, 1.0)
    end
    if bass_active and bass_patterns[bass_pattern_idx] and bass_patterns[bass_pattern_idx][playhead_bass] then
      play_bass(bass_pattern_idx, playhead_bass, 1.0)
    end
  end
end

-- ──────────────────────────────────────────────
-- GRID INTERFACE
-- ──────────────────────────────────────────────

local g = grid.connect()

local function grid_redraw()
  g:all(0)
  
  -- Rows 1-3 left: drum patterns
  for row = 1, 3 do
    for col = 1, 8 do
      if drum_patterns[row][col] then
        g:led(col, row, 15)
      elseif row == drum_pattern_idx then
        g:led(col, row, 5)
      end
    end
  end
  
  -- Rows 1-3 right: bass patterns
  for row = 1, 3 do
    for col = 9, 16 do
      local bass_col = col - 8
      if bass_patterns[row][bass_col] > 0 then
        local brightness = scale(bass_patterns[row][bass_col], 0, 127, 5, 15)
        g:led(col, row, brightness)
      elseif row == bass_pattern_idx then
        g:led(col, row, 2)
      end
    end
  end
  
  -- Row 4: playheads
  g:led(playhead_drums, 4, 10)
  g:led(playhead_bass + 8, 4, 10)
  
  -- Row 5: divider
  for col = 1, 16 do
    if col == divider_val * 4 then
      g:led(col, 5, 15)
    else
      g:led(col, 5, 2)
    end
  end
  
  -- Row 6: morph scrub
  local scrub_col = math.floor(scale(morph_scrub_pos, 0, 1, 1, 16))
  for col = 1, 16 do
    if col == scrub_col then
      g:led(col, 6, 15)
    else
      g:led(col, 6, 2)
    end
  end
  
  -- Row 7: mute toggles
  g:led(4, 7, drum_active and 15 or 2)
  g:led(12, 7, bass_active and 15 or 2)
  
  -- Row 8: save slots
  for slot = 1, 16 do
    if save_slots[slot] then
      g:led(slot, 8, 5)
    else
      g:led(slot, 8, 2)
    end
  end
  
  g:refresh()
end

local function grid_key(x, y, z)
  if z == 0 then return end  -- only on press
  
  -- Row 1-3: drum/bass patterns
  if y >= 1 and y <= 3 then
    if x <= 8 then
      -- Drum pattern edit
      drum_pattern_idx = y
      drum_patterns[y][x] = not drum_patterns[y][x]
    else
      -- Bass pattern edit
      bass_pattern_idx = y
      bass_patterns[y][x - 8] = (bass_patterns[y][x - 8] == 0) and 60 or 0
    end
  
  -- Row 4: playhead control
  elseif y == 4 then
    if x <= 8 then
      playhead_drums = x
    else
      playhead_bass = x - 8
    end
  
  -- Row 5: divider
  elseif y == 5 then
    divider_val = math.ceil(scale(x, 1, 16, 0.25, 4))
  
  -- Row 6: morph scrub
  elseif y == 6 then
    morph_scrub_pos = scale(x, 1, 16, 0, 1)
  
  -- Row 7: mute toggles
  elseif y == 7 then
    if x <= 8 then
      drum_active = not drum_active
    else
      bass_active = not bass_active
    end
  
  -- Row 8: save slots
  elseif y == 8 then
    save_slot_hold_time[x] = util.time()
  end
  
  grid_redraw()
end

-- ──────────────────────────────────────────────
-- KEY/ENC HANDLERS
-- ──────────────────────────────────────────────

local key_state = {false, false, false}  -- k1, k2, k3
local enc_state = {0, 0, 0}  -- encoder values
local k1_k2_time = 0
local k1_k3_time = 0
local k2_tap_time = 0
local k2_tap_count = 0
local k2_double_tap_timer = 0

function key(n, z)
  key_state[n] = (z == 1)
  
  -- K1 menu
  if n == 1 and z == 1 then
    -- K1+K2: knob looper record
    if key_state[2] then
      k1_k2_time = util.time()
      return
    end
    -- K1+K3: robot mode
    if key_state[3] then
      k1_k3_time = util.time()
      return
    end
  end
  
  -- K2 play/stop
  if n == 2 and z == 1 then
    local now = util.time()
    if now - k2_tap_time < tap_double_tap_window then
      k2_tap_count = k2_tap_count + 1
    else
      k2_tap_count = 1
    end
    k2_tap_time = now
    k2_double_tap_timer = tap_double_tap_window
  end
  
  -- K3 randomize
  if n == 3 and z == 1 then
    for i = 1, drum_sequence_len do
      drum_patterns[drum_pattern_idx][i] = (math.random() > 0.5)
    end
    for i = 1, bass_sequence_len do
      bass_patterns[bass_pattern_idx][i] = (math.random() > 0.5) and 60 or 0
    end
    grid_redraw()
  end
end

function enc(n, delta)
  enc_state[n] = enc_state[n] + delta
  
  if n == 1 then
    bpm = constrain(bpm + delta * 5, 40, 300)
    bpm_display = tostring(bpm)
  elseif n == 2 then
    drum_pattern_idx = constrain(drum_pattern_idx + delta, 1, 3)
  elseif n == 3 then
    bass_pattern_idx = constrain(bass_pattern_idx + delta, 1, 3)
  end
end

-- ──────────────────────────────────────────────
-- SCREEN REDRAW
-- ──────────────────────────────────────────────

function redraw()
  screen.clear()
  screen.font_size(16)
  screen.move(10, 30)
  screen.text("50/50 " .. current_engine)
  
  screen.font_size(12)
  screen.move(10, 50)
  screen.text("BPM: " .. bpm_display)
  
  screen.move(10, 70)
  screen.text("Drum: " .. drum_pattern_names[drum_pattern_idx])
  
  screen.move(10, 90)
  screen.text("Bass: P" .. bass_pattern_idx .. " Oct" .. bass_octave_display)
  
  screen.update()
end

-- ──────────────────────────────────────────────
-- INIT
-- ──────────────────────────────────────────────

function init()
  load_state()
  clock.transport.start()
  clock.connect()
  midi.add_device({port = 1, name = "drums"})
  midi.add_device({port = 2, name = "bass"})
  grid_redraw()
end