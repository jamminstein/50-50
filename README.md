# 50/50

**norns script** — Grid-split drum + acid bass looper

Divides the grid in two: drums on the left, acid bass loops on the right. Every load auto-randomizes both sides from a bank of 24 drum patterns and 24 bass patterns (including Euclidean patterns). The fun is finding magical combinations.

## Controls

| Control | Action |
|---------|--------|
| ENC1 | BPM |
| ENC2 | Drum pattern |
| ENC3 | Bass pattern |
| K2 | Play / Stop |
| K2 double-tap | Tap tempo |
| K3 | Randomize both sides |

## Grid Layout

```
Rows 1-3 left  (cols 1-8)  : drum pattern selector
Rows 1-3 right (cols 9-16) : bass pattern selector
Row 4                       : playheads
Row 5                       : divider
Row 6                       : morph scrub
Row 7 left                  : mute / stutter drums
Row 7 right                 : mute / stutter bass
Row 8                       : 16 save slots (hold 3s = save, tap = recall)
```

## MIDI Output
- Drums → Channel 1
- Bass → Channel 2

## Features
- 24 hand-crafted drum patterns + 12 Euclidean drum patterns
- 24 hand-crafted bass patterns + 12 Euclidean bass patterns
- Pattern morphing (gradual crossfade between patterns)
- Per-side mute and stutter
- Tap tempo
- 16 save slots on grid row 8
- Params: portamento, swing, humanize, morph speed, step probability

## Installation
```
~/dust/code/50-50/50-50.lua
```
Load from the norns SELECT menu.
