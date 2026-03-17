-- 50/50 v14
-- drums + bass sequencer / Supertonic engine
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

engine.name = "Supertonic"

local midi_out
local DRUM_CH      = 1
local BASS_CH      = 2
local grid_device
local clock_id
local morph_clock_id

-- ─────────────────────────────────────────────
-- NOTE NAMES
-- ─────────────────────────────────────────────
local NOTE_NAMES = {"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"}
local function note_name(midi)
  return NOTE_NAMES[(midi%12)+1]..tostring(math.floor(midi/12)-1)
end
local function midi_to_hz(note)
  return 440*(2^((note-69)/12))
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
  -- length multiplier
  drum_len_mult     = 1,  -- 0.5, 1, 2
  bass_len_mult     = 1,
}

-- ─────────────────────────────────────────────
-- SUPERTONIC DRUM PATCHES
-- param order: distAmt, eQFreq, eQGain, level, mix,
--              modAmt, modMode, modRate,
--              nEnvAtk, nEnvDcy, nEnvMod, nFilFrq, nFilMod, nFilQ, nStereo,
--              oscAtk, oscDcy, oscFreq, oscWave,
--              oscVel, nVel, modVel,
--              fx_lowpass_freq, fx_lowpass_rq
-- modMode: 0=decay sweep 1=sine LFO 2=random
-- nEnvMod: 0=exp 1=lin 2=clap
-- nFilMod: 0=LP 1=BP 2=HP
-- oscWave: 0=sine 1=tri 2=saw
-- ─────────────────────────────────────────────
local DRUM_PATCHES = {
  -- Sub Kick: very deep pitch sweep, long decay, mostly oscillator
  [24] = {6,  60,  3, -2, 90, 14, 0, 7,  0, 35,  0,  600, 2, 1.2, 0.0, 1, 400, 40,  0, 1.0, 0.5, 0.8, 8000, 0.7},
  -- Kick: 808-style, pitch sweep down, transient click from HP noise
  [36] = {8,  80,  2, -2, 85, 18, 0, 8,  0, 40,  0,  800, 2, 1.5, 0.0, 1, 280, 55,  0, 1.0, 0.6, 1.0, 8000, 0.7},
  -- Rimshot: short sine + BP noise burst
  [37] = {3, 1800, 4, -6, 40,  4, 0, 10, 0, 22,  0, 1800, 1, 3.0, 0.1, 0, 25,  800, 0, 1.0, 1.0, 0.5, 12000,0.8},
  -- Snare: osc body + wide BP noise
  [38] = {5, 2400, 2, -3, 45,  6, 0, 8,  0, 180, 0, 3000, 1, 0.8, 0.3, 0, 120, 200, 0, 1.0, 1.0, 0.8, 10000,0.7},
  -- Hand Clap: clap mode (nEnvMod=2), almost all noise, BP-filtered
  [39] = {2, 1500, 0, -4,  5,  0, 0, 0,  0, 60,  2, 1500, 1, 1.5, 0.5, 0, 40,  600, 0, 0.0, 1.0, 0.0, 8000, 0.8},
  -- Electric Snare: tight, higher-pitched than snare
  [40] = {4, 3000, 2, -4, 42,  5, 0, 9,  0, 100, 0, 4000, 1, 1.0, 0.2, 0, 80,  220, 0, 1.0, 1.0, 0.7, 10000,0.7},
  -- Closed HH: very short HP noise + saw transient
  [42] = {0,10000, 2, -8,  5,  0, 0, 0,  0, 18,  0, 9000, 2, 0.8, 0.1, 0, 20, 4000, 2, 0.5, 1.0, 0.0, 14000,0.8},
  -- Low Tom: pitched sine, pitch sweep, LP noise body
  [45] = {4, 1500, 0, -4, 75, 10, 0, 6,  0, 60,  0, 1500, 0, 1.5, 0.2, 1, 180, 100, 0, 1.0, 0.5, 0.8, 8000, 0.7},
  -- Open HH: longer HP noise decay + saw
  [46] = {0,10000, 2, -7,  6,  0, 0, 0,  0, 90,  0, 9000, 2, 0.8, 0.2, 0, 80, 4000, 2, 0.5, 1.0, 0.0, 14000,0.8},
  -- Crash Cymbal: long BP noise wash + saw ring
  [49] = {2, 5000, 0, -6,  8,  0, 0, 0,  0, 500, 0, 5000, 1, 0.6, 0.8, 0, 600,3000, 2, 0.3, 1.0, 0.0, 16000,0.9},
  -- High Tom: like low tom but higher pitch, tighter
  [50] = {3, 1200, 0, -4, 72,  9, 0, 7,  0, 50,  0, 1200, 0, 1.2, 0.2, 1, 150, 180, 0, 1.0, 0.5, 0.8, 8000, 0.7},
  -- Ride Cymbal: long BP noise ring + saw shimmer
  [51] = {1, 4500, 0, -8, 12,  0, 0, 0,  0, 350, 0, 4500, 1, 0.7, 0.5, 0, 400,3200, 2, 0.3, 1.0, 0.0, 16000,0.9},
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
end
local function midi_note_off(ch, note)
  if midi_out then midi_out:note_off(note, 0, ch) end
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

-- Fire a drum hit via Supertonic engine.
-- Velocity scales oscVel, nVel, modVel; density scales overall amplitude.
local function fire_drum(note, vel, extra_delay)
  local p = DRUM_PATCHES[note]
  if not p then return end
  local density  = params:get("drum_density") / 100.0
  local vel_norm = (vel / 127) * density
  clock.run(function()
    local d = extra_delay + humanize_delay() + swing_delay(state.drum_step)
    if d > 0 then clock.sleep(d) end
    engine.supertonic(
      p[1],            -- distAmt
      p[2],            -- eQFreq
      p[3],            -- eQGain
      p[4],            -- level (dB)
      p[5],            -- mix
      p[6],            -- modAmt
      p[7],            -- modMode
      p[8],            -- modRate
      p[9],            -- nEnvAtk
      p[10],           -- nEnvDcy
      p[11],           -- nEnvMod
      p[12],           -- nFilFrq
      p[13],           -- nFilMod
      p[14],           -- nFilQ
      p[15],           -- nStereo
      p[16],           -- oscAtk
      p[17],           -- oscDcy
      p[18],           -- oscFreq
      p[19],           -- oscWave
      p[20] * vel_norm, -- oscVel (velocity + density scaled)
      p[21] * vel_norm, -- nVel   (velocity + density scaled)
      p[22] * vel_norm, -- modVel (velocity + density scaled)
      p[23],           -- fx_lowpass_freq
      p[24]            -- fx_lowpass_rq
    )
    state.drum_level = math.min(1, vel_norm * 1.3)
  end)
end

-- Bass is MIDI-only (only one engine can load at a time).
-- Timing offset and level display are handled here.
local function fire_bass(note, vel, extra_delay)
  local amp = (vel / 127) * 0.82
  clock.run(function()
    local d = extra_delay + humanize_delay()
    if d > 0 then clock.sleep(d) end
    state.bass_level = math.min(1, amp * 1.3)
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
  if d_cell and not state.drum_muted and prob_gate(d_step) then
    local note,vel = d_cell[1], humanize_vel(d_cell[2])
    fire_drum(note, vel, 0)
    midi_note_on(DRUM_CH, note, vel)
    clock.run(function() clock.sleep(0.05) midi_note_off(DRUM_CH,note) end)
  else
    state.drum_level=state.drum_level*0.5
  end
  if not state.stutter_drum then state.drum_step=state.drum_step+1 end

  -- bass (12ms offset)
  local b_cell = get_step(get_bass_loop_maybe_mutated,
    state.bass_pattern, state.bass_morph_target,
    state.morph_pos, b_step, state.bass_len_mult)
  if active_bass_note_midi then
    midi_note_off(BASS_CH, active_bass_note_midi)
    active_bass_note_midi=nil
  end
  if b_cell and not state.bass_muted and prob_gate(b_step) then
    local note,vel = b_cell[1], humanize_vel(b_cell[2])
    fire_bass(note, vel, 0.012)
    midi_note_on(BASS_CH, note, vel)
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

  screen_redraw()
  grid_redraw()
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
    screen_redraw()
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
    grid_redraw() screen_redraw()
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
        if state.drum_muted then midi_note_off(DRUM_CH,36) end
      elseif x<=8 then
        state.stutter_drum=not state.stutter_drum
        if state.stutter_drum then state.stutter_step=state.drum_step end
      elseif x<=12 then
        state.bass_muted=not state.bass_muted
        if state.bass_muted and active_bass_note_midi then
          midi_note_off(BASS_CH,active_bass_note_midi)
          active_bass_note_midi=nil state.active_bass_note=nil
        end
      else
        state.stutter_bass=not state.stutter_bass
        if state.stutter_bass then state.stutter_step=state.bass_step end
      end
    end
    grid_redraw() screen_redraw()
  end
end

-- ─────────────────────────────────────────────
-- KEYS & ENCODERS
-- ─────────────────────────────────────────────
local k2_last_press = 0
local k2_tap_pending = false

function key(n, z)
  if n==1 then return end
  if z==1 then
    if n==2 then
      local now = os.clock()
      if now - k2_last_press < 0.4 then
        -- double tap = tap tempo
        tap_tempo()
        k2_tap_pending=false
      else
        k2_tap_pending=true
        local press_time=now
        clock.run(function()
          clock.sleep(0.4)
          if k2_tap_pending then
            -- single tap = play/stop
            k2_tap_pending=false
            state.playing=not state.playing
            if state.playing then
              state.drum_step=1 state.bass_step=1
              start_clock()
            else
              if clock_id then clock.cancel(clock_id) end
              if active_bass_note_midi then
                midi_note_off(BASS_CH,active_bass_note_midi)
                active_bass_note_midi=nil state.active_bass_note=nil
              end
            end
            screen_redraw() grid_redraw()
          end
        end)
      end
      k2_last_press=now
    elseif n==3 then
      -- single press: randomize
      state.drum_pattern=math.random(1,TOTAL_DRUM)
      state.bass_pattern=math.random(1,TOTAL_BASS)
      state.drum_step=1 state.bass_step=1
      state.drum_morph_target=nil state.bass_morph_target=nil
      state.morph_pos=0
    end
    screen_redraw() grid_redraw()
  end
end

function enc(n, d)
  if n==1 then
    state.bpm=util.clamp(state.bpm+d, 40, 300)
    params:set("clock_tempo", state.bpm)
  elseif n==2 then
    state.drum_pattern=util.clamp(state.drum_pattern+d, 1, TOTAL_DRUM)
    state.drum_step=1
  elseif n==3 then
    state.bass_pattern=util.clamp(state.bass_pattern+d, 1, TOTAL_BASS)
    state.bass_step=1
  end
  screen_redraw() grid_redraw()
end

-- ─────────────────────────────────────────────
-- PARAMS
-- ─────────────────────────────────────────────
local function add_params()
  params:add_separator("50/50")

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

  params:add_number("midi_out_device","MIDI Out Device",1,4,1)
  params:set_action("midi_out_device",function(v)
    midi_out=midi.connect(v)
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

  add_params()

  midi_out=midi.connect(params:get("midi_out_device"))

  local g=grid.connect()
  if g.device~=nil then
    grid_device=g
    grid_device.key=grid_key
  end

  params:set("clock_tempo", state.bpm)
  start_morph_clock()

  screen_redraw()
  grid_redraw()

  print("50/50 v14 ready -- Supertonic engine")
  print("K2: play/stop  double-K2: tap tempo")
  print("K3: randomize")
  print("PARAMS: mutate, density, length mult, step prob")
  print("grid r7 col1-4: mute drums  col5-8: stutter drums")
  print("grid r7 col9-12: mute bass  col13-16: stutter bass")
  print("bass: MIDI ch2 only (Supertonic handles drums)")
end

function cleanup()
  if clock_id       then clock.cancel(clock_id)       end
  if morph_clock_id then clock.cancel(morph_clock_id) end
  if active_bass_note_midi then midi_note_off(BASS_CH,active_bass_note_midi) end
end
