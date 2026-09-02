//============================================================================
//  Sega System C/C-2 external colour RAM (the EPM5032 palette path)
//
//  This is the one place where a C-2 board stops being a Mega Drive.  The VDP's
//  own 64-entry CRAM is bypassed; the raw 6-bit colour index the VDP would have
//  used is taken out of the chip and combined with four bits the EPM5032
//  supplies to address 2048 words of external colour RAM.
//
//  Index (11 bits), from segac2.cpp recompute_palette_tables():
//
//    background:  {palbank, 1'b0, bg_palbase, pal_line, colour}
//    sprite:      {palbank, 1'b1, sp_palbase, pal_line, colour}
//
//  pal_line = COL_IDX[5:4] and colour = COL_IDX[3:0] come from the VDP,
//  palbase from the protection chip, palbank from I/O port H.
//
//  Alt palette mode (control_w bit 2 low) swizzles the address instead.  Only
//  ribbit and twinsqua use it.  The background and sprite swizzles differ, and
//  the CPU side is swizzled too (palette_r/palette_w) -- a core that did only
//  the pixel side would look right until the game wrote a colour.  All three
//  are here.
//
//  Colour word is xBGRBBBB GGGGRRRR: four bits per channel plus one extra
//  "half" bit each in 14:12, giving five bits per channel (segac2.cpp:481).
//  Shadow halves it; highlight halves it and sets bit 4.  MAME's own comment
//  next to the highlight case is "how is it calculated on c2?", so treat any
//  difference there as unverified rather than as a defect in this module.
//============================================================================

module c2_palette
(
	input             CLK,

	// ---- CPU port: 0x8C0000-0x8C0FFF ----
	input             CPU_SEL,
	input      [10:1] CPU_A,        // byte address within the window
	input      [15:0] CPU_DI,
	input             CPU_UDS_N,
	input             CPU_LDS_N,
	input             CPU_RNW,
	output     [15:0] CPU_DO,

	// ---- configuration ----
	input       [1:0] PALBANK,      // I/O port H [1:0] -> colour RAM A10:A9
	input       [1:0] BG_PALBASE,   // protection write [1:0]
	input       [1:0] SP_PALBASE,   // protection write [3:2]
	input             ALT_MODE,     // control_w bit 2 low

	// ---- pixel port, from the VDP ----
	input       [5:0] COL_IDX,      // {palette line, colour}
	input             COL_SPR,      // the winning layer was a sprite
	input       [1:0] COL_MODE,     // 0 shadow, 1 normal, 2 highlight
	input             COL_BORDER,   // outside the active display

	output reg  [7:0] R,
	output reg  [7:0] G,
	output reg  [7:0] B,

	// observation only
	output     [15:0] DBG_PIXQ,
	output     [10:0] DBG_PIX_IDX,
	output     [10:0] DBG_CPU_IDX,
	output reg        DBG_STORED_NZ    // a non-zero word has been written
);

//--------------------------------------------------------------------
// Address arithmetic
//--------------------------------------------------------------------
// The CPU sees a 512-word window; I/O port H supplies the two high bits.
// palette_r / palette_w, segac2.cpp:466 and :460.
wire [8:0] cpu_off = CPU_A[9:1];
wire [8:0] cpu_swz = { cpu_off[7],      // (off << 1) & 0x100
                       cpu_off[5],      // (off << 2) & 0x080
                      ~cpu_off[8],      // (~off >> 2) & 0x040
                       cpu_off[6],      // (off >> 1) & 0x020
                       cpu_off[4:0] };  // off & 0x01f
wire [10:0] cpu_idx = {PALBANK, ALT_MODE ? cpu_swz : cpu_off};

// Pixel side.  pal is the 9-bit value MAME calls bgpal/sppal with the colour
// index folded into the low nibble: bit 8 selects the sprite half, 7:6 the
// palbase, 5:4 the palette line, 3:0 the colour.
//
// The sprite half of the colour RAM is reached only by a sprite pixel drawn in
// *normal* mode.  segac2.cpp:1767 switches on bits 7:6 of the VDP's raw line:
// 0x80 is the only code that selects sp_pal_lookup, and 315_5313.cpp:2181 only
// emits it for `(sprite) normal pri, no shadow sprite, no highlight`.  A
// shadowed sprite lands on code 0x00 and a highlighted one on 0xC0, and both
// of those read the *background* lookup.  Using SP_PALBASE for every sprite
// pixel gets the plain ones right and every shaded one wrong, which on the
// Puyo Puyo title screen is exactly the shine sweeping across the logo.
wire       spr_eff = COL_SPR & (COL_MODE == 2'd1);
wire [1:0] palbase = spr_eff ? SP_PALBASE : BG_PALBASE;
wire [8:0] pal     = {spr_eff, palbase, COL_IDX};

// recompute_palette_tables(), segac2.cpp:532.  The two expressions really are
// different -- the sprite one inverts two bits the background one does not.
wire [8:0] pal_alt_bg  = { pal[7],       // (pal << 1) & 0x180, high bit
                           pal[6],       // (pal << 1) & 0x180, low bit
                          ~pal[8],       // (~pal >> 2) & 0x040
                           pal[5:4],     // pal & 0x030
                           pal[3:0] };
wire [8:0] pal_alt_spr = { ~pal[6],      // (~pal << 2) & 0x100
                            pal[5],      // ( pal << 2) & 0x080
                           ~pal[8],      // (~pal >> 2) & 0x040
                            pal[7],      // ( pal >> 2) & 0x020
                            pal[4],      // pal & 0x010
                            pal[3:0] };

wire [8:0]  pal_eff = ALT_MODE ? (spr_eff ? pal_alt_spr : pal_alt_bg) : pal;
wire [10:0] pix_idx = {PALBANK, pal_eff};

//--------------------------------------------------------------------
// 2048 x 16, split into byte lanes so the 68000's UDS/LDS can write one
// half.  Two simple dual-port RAMs: CPU read/write on port A, pixel read
// on port B.
//--------------------------------------------------------------------
reg  [7:0] cram_u[2048];
reg  [7:0] cram_l[2048];
reg [15:0] cpu_q;
reg [15:0] pix_q;

wire cpu_we_u = CPU_SEL & ~CPU_RNW & ~CPU_UDS_N;
wire cpu_we_l = CPU_SEL & ~CPU_RNW & ~CPU_LDS_N;

always @(posedge CLK) begin
	if (cpu_we_u) cram_u[cpu_idx] <= CPU_DI[15:8];
	if (cpu_we_l) cram_l[cpu_idx] <= CPU_DI[7:0];
	cpu_q <= {cram_u[cpu_idx], cram_l[cpu_idx]};
	pix_q <= {cram_u[pix_idx], cram_l[pix_idx]};
end

assign CPU_DO = cpu_q;

assign DBG_PIXQ    = pix_q;
assign DBG_PIX_IDX = pix_idx;
assign DBG_CPU_IDX = cpu_idx;
always @(posedge CLK)
	if ((cpu_we_u && CPU_DI[15:8]) || (cpu_we_l && CPU_DI[7:0])) DBG_STORED_NZ <= 1;

//--------------------------------------------------------------------
// Colour expansion
//--------------------------------------------------------------------
wire [4:0] r5 = {pix_q[3:0],  pix_q[12]};
wire [4:0] g5 = {pix_q[7:4],  pix_q[13]};
wire [4:0] b5 = {pix_q[11:8], pix_q[14]};

function automatic [4:0] shade(input [4:0] c, input [1:0] mode);
	case (mode)
		2'd0:    shade = {1'b0, c[4:1]};   // shadow:    c >> 1
		2'd2:    shade = {1'b1, c[4:1]};   // highlight: (c >> 1) | 0x10
		default: shade = c;                // normal
	endcase
endfunction

function automatic [7:0] pal5(input [4:0] c);
	pal5 = {c, c[4:2]};                    // MAME pal5bit
endfunction

// pix_q lags the index by one clock, so the mode and border flags have to lag
// with it or a shadowed pixel gets the previous pixel's colour.
reg [1:0] mode_d;
reg       border_d;
always @(posedge CLK) begin
	mode_d   <= COL_MODE;
	border_d <= COL_BORDER;
	R <= border_d ? 8'h00 : pal5(shade(r5, mode_d));
	G <= border_d ? 8'h00 : pal5(shade(g5, mode_d));
	B <= border_d ? 8'h00 : pal5(shade(b5, mode_d));
end

endmodule
