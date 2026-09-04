# Sega System C / C-2 core for MiSTer (Arcade-SystemC2)

An FPGA implementation of Sega's **System C** and **System C-2** arcade hardware for the
[MiSTer](https://github.com/MiSTer-devel/Wiki_MiSTer/wiki) platform: a 68000 at 8.95 MHz, the
315-5313 VDP with its internal colour RAM bypassed in favour of 2048 words of **external colour
RAM**, the Sega 315-5296 I/O chip, a YM3438, the VDP's own SN76489 PSG, a uPD7759 sample player,
and the per-game **317-xxxx protection chip**.

This is the hardware behind Puyo Puyo, Columns, Thunder Force AC, Tant-R, Ichidant-R, Bloxeed,
Borench, Ribbit!, Stack Columns, PotoPoto and about forty other machines.

> ## Please read first: this is a "slopcore"
>
> **Every line of System C/C-2 specific logic in this repository was written by an AI coding
> assistant** (Anthropic's Claude), working from MAME's source under human direction. None of it
> was hand-written by a hardware engineer.
>
> The core has been checked against MAME reference frames in simulation and runs the games listed
> below on real MiSTer hardware, but **it makes no claim of cycle accuracy** and no claim to
> reproduce the 315-5313, the 315-5296 or the 317-xxxx silicon. Where the real chips are
> undocumented the core does what MAME does, and where MAME's own comments say "guess", so does
> this.
>
> **All credit belongs to the original creators listed below.** This project only exists because
> of the upstream Genesis core it was adapted from, the CPU and sound cores it reuses, the MiSTer
> framework, and the MAME team whose driver is the only public documentation of this hardware.
> Use at your own risk and expect bugs.

## Credits

This core is a fork of **[Genesis_MiSTer](https://github.com/MiSTer-devel/Genesis_MiSTer)** by
**Sorgelig** and contributors, taken at commit `adc0c42` ("Release 20230224"). The 315-5313 VDP,
its block RAM wrappers, the SDRAM controller, the PLLs and the MiSTer framework plumbing are that
project's work. System C-2 is a Mega Drive in arcade clothing, so a Mega Drive core is the honest
starting point: what this fork adds is the external colour RAM, the arcade I/O, the protection
chip, the rearranged interrupts and the MRA ROM loader, and what it removes is everything a
cartridge console needs and an arcade board does not.

| Component | Author | Licence | Path |
|---|---|---|---|
| Genesis_MiSTer (upstream core) | Sorgelig, Gregory Estrade, Till Harbaum, György Szombathelyi and contributors | GPL-2.0 | `rtl/vdp.vhd`, `rtl/vdp_common.vhd`, `rtl/bram.vhd`, `rtl/mlab.vhd`, `rtl/pll*` |
| **fx68k** cycle-exact 68000 | Jorge Cwik (ijor) | see `rtl/FX68K/LICENSE` | `rtl/FX68K/` |
| **jt12** YM2612/YM3438 (OPN2) | Jose Tejada (jotego) | GPL-3.0 | `rtl/jt12/` |
| **jt89** SN76489 PSG | Jose Tejada (jotego) | GPL-3.0 | `rtl/jt89/` |
| **jt7759** uPD7759 ADPCM | Jose Tejada (jotego) | GPL-3.0 | `rtl/jt7759/` |
| `sdram.sv` | Sorgelig | GPL-3.0 | `rtl/` |
| MiSTer framework | Sorgelig and the MiSTer-devel project | GPL-2.0 / GPL-3.0 / LGPL | `sys/` |
| PLL and megafunction wrappers | Intel | Intel FPGA licence | `rtl/pll*`, `sys/pll_*` |

Taken from Genesis_MiSTer and used essentially unchanged: `rtl/vdp.vhd` and `rtl/vdp_common.vhd`
(the 315-5313 itself), `rtl/bram.vhd` and `rtl/mlab.vhd` (block-RAM wrappers around `altsyncram`),
`rtl/sdram.sv` (the three-port SDRAM controller), `rtl/jt89/` (the PSG that lives inside the VDP),
and `rtl/pll*` with `sys/` for clocking and the framework. Copyright holders named in those files
include Gregory Estrade, Till Harbaum, Alexey Melnikov (Sorgelig) and György Szombathelyi.

Replaced rather than reused: Genesis_MiSTer's `rtl/system.sv` became `rtl/c2_system.sv`. The
68000, the VDP wiring and the MBUS arbiter keep the upstream shape, including the VDP's DMA bus
mastering; everything a cartridge console needs and an arcade board does not — Z80, cartridge
mapper, SVP, multitap, lightgun, cheat engine, SRAM banking — is gone.

Hardware knowledge came from:

- **MAME** (`src/mame/sega/segac2.cpp` by David Haywood and Aaron Giles,
  `src/mame/sega/315_5296.cpp` by hap with thanks to Charles MacDonald,
  `src/devices/video/315_5313.cpp`, `src/devices/sound/upd7759.cpp`), pinned at **0.276**. No
  service manual, schematic or die shot for System C/C-2 has been located; MAME is the authority
  for everything here; every hardware fact in this core is cited to a line in those files.
- **system16.com** for the board-level specification.
- The games themselves are the work of **Sega**, **Compile** and the other original developers.

**Local change to `rtl/vdp.vhd`.** Four output ports (`COL_IDX`, `COL_SPR`, `COL_MODE`,
`COL_BORDER`) expose the raw colour index the VDP would have used to address its internal CRAM —
a System C-2 board does not use that CRAM, the index goes off-chip instead. One existing statement
is also changed: with `BORDER_EN = 0` the exported `VBL` was computed from its own comparison on
`HV_VCNT`, which advances at `H_INT_POS`, while the pixel priority chain tests `V_ACTIVE_DISP`,
updated at `HBLANK_START`. The two windows were one line apart, so the frame was the right size
and held the wrong 224 lines; it is now `VBL <= not V_ACTIVE_DISP`. This affects the borderless
path only, which is the one an arcade core uses; the `BORDER_EN = 1` path already agreed, because
there `VBL` comes from `VBL_AREA`, updated at the same point. The change is offered under
Genesis_MiSTer's GPL-2.0-or-later.

**Protection tables.** The 317-xxxx chips are a two-stage FIFO around a purely combinational
8-in/4-out function — 25 of them in MAME's driver, one per chip — so each collapses to a 256×4
lookup table. The tables are generated by parsing and evaluating the boolean expressions in
`segac2.cpp` rather than re-typing them, and they travel in the MRA rather than the RTL, which is
what lets a single build serve every machine in the family.

## Supported games

All 57 machines in MAME's `segac2.cpp` have an MRA in `releases/`, and every one of them has been
started on real hardware: **53 reach their attract or title screen**. The four marked as verified
below are additionally compared frame-by-frame against MAME in simulation, and were chosen because
between them they cover every structural branch in the design -- the no-PCM path, the
no-protection path, PCM bank switching, the alternate palette address mapping, and a `ROM_COPY`
mirror the MRA has to reproduce.

| Game | Set | Board | Protection | Samples | State |
|---|---|---|---|---|---|
| Bloxeed (US, C System, Rev A) | `bloxeedu` | System C | none | none | boots on hardware |
| Bloxeed (World, C System) | `bloxeedc` | System C | none | none | boots on hardware |
| Borench (Japan) | `borenchj` | System C-2 | yes | 1 bank | boots on hardware |
| Borench (set 1) | `borench` | System C-2 | yes | 1 bank | boots on hardware |
| Borench (set 2) | `borencha` | System C-2 | yes | 1 bank | boots on hardware |
| Columns (Japan) | `columnsj` | System C | yes | none | boots on hardware |
| Columns (US, cocktail, Rev A) | `columnsu` | System C | yes | none | boots on hardware |
| Columns (World) | `columns` | System C | yes | none | boots and plays; **7/7 frames pixel-identical to MAME** |
| Columns II: The Voyage Through Time (Japan) | `column2j` | System C | yes | none | boots on hardware |
| Columns II: The Voyage Through Time (World) | `columns2` | System C | yes | none | boots on hardware |
| Monita to Rimoko no Head On Channel (prototype, hack) | `headonch` | System C-2 | none | 2 banks | boots on hardware |
| OOPArts (prototype, joystick hack) | `ooparts` | System C-2 | none | 2 banks | boots on hardware |
| Poto Poto (Japan, Rev A) | `potopoto` | System C-2 | yes | 2 banks | boots on hardware |
| Print Club (Japan Vol.1) | `pclubj` | System C-2 | yes | 4 banks | boots on hardware |
| Print Club (Japan Vol.2) | `pclubjv2` | System C-2 | yes | 4 banks | boots on hardware |
| Print Club (Japan Vol.3) | `pclubjv3` | System C-2 | yes | 4 banks | **does not work** |
| Print Club (Japan Vol.4) | `pclubjv4` | System C-2 | yes | 4 banks | boots on hardware |
| Print Club (Japan Vol.5) | `pclubjv5` | System C-2 | yes | 4 banks | boots on hardware |
| Print Club (World) | `pclub` | System C-2 | yes | 4 banks | boots on hardware |
| Puyo Puyo (Japan, Rev A) | `puyoja` | System C-2 | yes | 1 bank | boots on hardware |
| Puyo Puyo (Japan, Rev B) | `puyoj` | System C-2 | yes | 1 bank | boots on hardware |
| Puyo Puyo (World) | `puyo` | System C-2 | yes | 1 bank | boots and plays; 5/7 frames pixel-identical |
| Puyo Puyo (World, bootleg) | `puyobl` | System C-2 | yes | 1 bank | boots on hardware |
| Puyo Puyo 2 (Japan) | `puyopuy2` | System C-2 | yes | 4 banks | boots on hardware |
| Puzzle & Action: Ichidant-R (Japan) | `ichirj` | System C-2 | yes | 4 banks | boots on hardware |
| Puzzle & Action: Ichidant-R (Japan) (bootleg) | `ichirjbl` | System C | none | none | **does not work** |
| Puzzle & Action: Ichidant-R (Korea) | `ichirk` | System C-2 | yes | 4 banks | boots on hardware |
| Puzzle & Action: Ichidant-R (World) | `ichir` | System C-2 | yes | 4 banks | boots on hardware |
| Puzzle & Action: Ichidant-R (World) (bootleg) | `ichirbl` | System C-2 | none | 4 banks | boots on hardware |
| Puzzle & Action: Tant-R (Japan) | `tantr` | System C-2 | yes | 2 banks | boots on hardware |
| Puzzle & Action: Tant-R (Japan) (bootleg set 1) | `tantrbl` | System C-2 | none | 2 banks | boots on hardware |
| Puzzle & Action: Tant-R (Japan) (bootleg set 2) | `tantrbl2` | System C | yes | none | boots on hardware |
| Puzzle & Action: Tant-R (Japan) (bootleg set 3) | `tantrbl3` | System C | yes | none | boots on hardware |
| Puzzle & Action: Tant-R (Japan) (bootleg set 4) | `tantrbl4` | System C-2 | none | 2 banks | boots on hardware |
| Puzzle & Action: Tant-R (Korea) | `tantrkor` | System C-2 | yes | 2 banks | boots on hardware |
| Ribbit! | `ribbit` | System C-2 | yes | 4 banks | boots and plays; 2/7 frames pixel-identical; alt palette mode |
| Ribbit! (Japan) | `ribbitj` | System C-2 | yes | 4 banks | boots on hardware |
| SegaSonic Bros. (prototype, hack) | `ssonicbr` | System C-2 | none | 1 bank | boots and plays; 5/7 frames pixel-identical |
| SegaSonic Cosmo Fighter (Japan) | `sonicfgtj` | System C-2 | none | 2 banks | boots on hardware |
| SegaSonic Cosmo Fighter (World) | `sonicfgt` | System C-2 | none | 2 banks | boots on hardware |
| SegaSonic Popcorn Shop (Rev B) | `sonicpop` | System C-2 | none | 2 banks | boots on hardware |
| Soreike! Anpanman Popcorn Koujou (Rev A) | `anpanmana` | System C-2 | none | 2 banks | boots on hardware |
| Soreike! Anpanman Popcorn Koujou (Rev B) | `anpanman` | System C-2 | none | 2 banks | boots on hardware |
| Stack Columns (Japan) | `stkclmnsj` | System C-2 | yes | 1 bank | boots on hardware |
| Stack Columns (World) | `stkclmns` | System C-2 | yes | 1 bank | boots on hardware |
| Thunder Force AC | `tfrceac` | System C-2 | yes | 2 banks | boots on hardware |
| Thunder Force AC (bootleg) | `tfrceacb` | System C-2 | none | 2 banks | **does not work** |
| Thunder Force AC (Japan) | `tfrceacj` | System C-2 | yes | 2 banks | boots on hardware |
| Thunder Force AC (Japan, prototype, bootleg) | `tfrceacjpb` | System C-2 | yes | 2 banks | **does not work** |
| Twin Squash | `twinsqua` | System C-2 | yes | 1 bank | boots on hardware |
| Waku Waku Anpanman | `wwanpanmo` | System C-2 | none | 2 banks | boots on hardware |
| Waku Waku Anpanman (Rev A) | `wwanpanm` | System C-2 | none | 2 banks | boots on hardware |
| Waku Waku Jumbo (Rev A) | `wwjumbo` | System C-2 | none | 2 banks | boots on hardware |
| Waku Waku Marine | `wwmarine` | System C-2 | none | 2 banks | boots on hardware |
| Waku Waku Pajero | `wwpajero` | System C-2 | none | 2 banks | boots on hardware |
| Waku Waku Sonic Patrol Car | `soniccar` | System C-2 | none | 2 banks | boots on hardware |
| Zunzunkyou no Yabou (Japan) | `zunkyou` | System C-2 | yes | 4 banks | boots on hardware |

Booting is not the same as playing. Beyond the four verified sets the games have been started
rather than played through, and the audio has not been checked by ear on any of them. The four
that do not work are explained under Known limitations.

**One build serves every set.** Nothing about a specific game is compiled into the core: the
memory layout, the DIP definitions, the button list and the 317-xxxx protection table all arrive
in the MRA's data stream.

Nineteen of the machines are clones that take part of their data from their parent, so both have
to be present for those. `wwjumbo` and `wwpajero` were added to `segac2.cpp` after the MAME 0.276
this core is pinned to; their layout and switch definitions are carried as data alongside the
pinned driver rather than by re-pointing it, which would put the frame-exact verification of the
four tested sets in question for the sake of two machines.

## Installation

1. Copy `releases/Arcade-SystemC2_20260902.rbf` to `_Arcade/cores/` on the MiSTer SD card.
2. Copy the `.mra` files from `releases/` to `_Arcade/`.

## Controls and options

- Seven buttons per player, named by the MRA and labelled in the MiSTer button-definition menu.
  The MRA's default pad assignment is:

  | Button 1 | Button 2 | Button 3 | Start | Coin | Service | Test |
  |---|---|---|---|---|---|---|
  | A | B | X | Start | Select | R | **L** |
- **Service and Test are two different cabinet switches**, not one. In a game's service menu,
  SERVICE moves the cursor and TEST activates the entry under it — which is what the menu's own
  "SELECT BY SERVICE BUTTON AND PUSH TEST BUTTON" is telling you. The OSD's
  **Enter Service Mode** item generates a TEST press for you; from inside the menu you need the
  mapped Test button.
- DIP switches come from each MRA's `<switches>` block, with the defaults MAME's driver declares
  (not "all switches off", which is a different machine — Puyo Puyo's Demo Sounds defaults to on).
- OSD: aspect ratio, scandoubler effects, DIP switches, enter service mode, reset.

Note that MiSTer writes a core's input map **once**, from the MRA's `<buttons default=...>`, and
never revises it. If you used an earlier build whose MRA had six buttons, delete
`config/inputs/<setname>_input_<vid>_<pid>_v3.map` so the seventh slot (Test) gets assigned.

## Known limitations

- **Audio is confirmed by ear on hardware** as of 2026-09-04: uPD7759 voice samples play, and the FM
  and PSG sit together in the mix. Three defects were fixed to get there, all of them past the point
  the simulation gates reach - the loader cleared `HAS_PCM` on the reset MiSTer issues after the ROM
  download, so the sample chip was disabled for the whole session; the sample base address was a
  23-bit concatenation into a 24-bit SDRAM port; and the mixer added jt12's output unscaled, which
  left the FM 27 dB under the PSG. What is gated in simulation is still the register stream the
  68000 writes to each chip, which matches MAME write for write on all four local sets, plus a check
  that a set which commands a sample actually fetches one. Levels beyond that are judged by ear.
- **Nothing is saved.** The board's 64 KB work RAM is battery-backed and holds bookkeeping and
  high scores; the core does not persist it, so it resets at power-off. Save states are not
  implemented either.
- Only the four sets above have MRAs and have been tested; the rest of `segac2.cpp` is untested.
- Residual differences against MAME, all in mid-display raster timing rather than in what is
  drawn: Puyo Puyo frames 120 and 300 (851 and 177 pixels of 71680), SegaSonic Bros. frames 600
  and 900, and five of Ribbit!'s seven sampled frames.
- SegaSonic Bros. does not write the two uPD7759 samples MAME writes at frame 285.
- **Four sets do not work.** Three of them fail for the same reason: MAME gives the machine a small
  per-game bus quirk that this core has no equivalent for.

  | set | what MAME does that the core does not |
  |---|---|
  | `tfrceacjpb` | forces the 315-5296 direction register to `0xF`, because the board writes a bad one. The core lets it through, so the service port reads as though TEST were held and the game boots into diagnostics. |
  | `tfrceacb` | ignores writes to `0x800000`, disabling the protection chip's palette-bank switching. The core passes them to the protection port, the palette bases end up wrong and the screen stays black. |
  | `ichirjbl` | adds a bootleg-specific read at `0x840108`. Without it the game's check fails and it never draws. |
  | `pclubjv3` | cause not identified. Its protection table is generated and populated, and the other five Print Club sets work. |

  Their parents and siblings are unaffected — `tfrceac`, `tfrceacj`, `ichir`, `ichirj`, `ichirk`,
  `ichirbl` and the rest all run.
- The six Print Club sets run their 68000 from a 52.867 MHz crystal rather than 53.693175, and the
  core's clocking is fixed. Five of the six boot regardless; only the ~1.5% timing difference
  remains, which has not been characterised.
- The Megalo 50 moving-seat machine configuration is a cabinet peripheral rather than board
  hardware and is out of scope; the sets that use it are otherwise unaffected.
- The Megalo 50 moving-seat device that MAME wires to Puyo Puyo and Ribbit! is a cabinet
  peripheral, not C-2 board hardware, and is out of scope.

## Building

Quartus Prime Lite 17.0.x, from the repository root:

```
quartus_sh --flow compile Arcade-SystemC2 -c Arcade-SystemC2
```

`sys/sys.tcl` registers `sys/build_id.tcl` as a Quartus pre-flow script, so `build_id.v` is
generated on every compile and is not tracked. The bitstream is written to
`output_files/Arcade-SystemC2.rbf`. The vendored `rtl/jt12/` ships its own Quartus projects, so
any build wrapper that searches the tree for a `.qpf` must be told which revision to use.

## How it was verified

The core is verified against MAME 0.276 rather than by looking at it.

- A Verilator bench runs each game's ROMs through the whole core — including the real `sdram.sv`
  against an SDRAM model, not a flat memory — and compares its frames, at fixed frame numbers,
  against MAME captures of the same frames. **Zero pixel tolerance**, deliberately: a frame is
  identical or it is a failure. Columns is identical on all seven sampled frames.
- Verilator cannot read VHDL and the VDP is 3700 lines of it, so the bench converts
  `rtl/vdp.vhd` with GHDL on every simulation build. The simulated VDP is generated from the same
  file Quartus compiles, so the two cannot drift.
- Sound is checked as a register stream, not as "it is not silent": a MAME Lua trace and the
  bench are compared write for write, per device, with the frame each stream starts on.
- Every MRA's ROM stream is expanded and verified byte-for-byte against the image the bench runs,
  and separately against MAME's own 68000 memory — an independent check, because two tools written
  from one wrong assumption agree with each other. That is not hypothetical: the MRA interleave
  maps were reversed and the checker shared the misreading, and only hardware saw it.
- The 317-xxxx protection tables are generated by parsing and evaluating the boolean expressions
  in `segac2.cpp` rather than re-typing them, then checked against the emulated device over every
  reachable state.
- All four games were booted, coined and played on a MiSTer.

The verification harness is not part of this repository.

## Licence

This project's own code is licensed GPL-2.0-or-later, inherited from the upstream core; see
`LICENSE`. The bundled third-party components keep their own licences as listed under Credits.
Because several of them (jt12, jt89, jt7759, `sdram.sv`) are GPL-3.0, the combined work is
effectively subject to GPL-3.0.
