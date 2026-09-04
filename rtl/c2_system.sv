//============================================================================
//  Sega System C / C-2
//
//  Replaces Genesis_MiSTer's rtl/system.sv.  The VDP, its VRAM wiring, the
//  68000 and the MBUS arbiter keep the shape of the original -- that code
//  solves 68000/VDP bus arbitration and VDP DMA bus mastering, which is the
//  part of a Mega Drive that is genuinely hard.  Everything a cartridge
//  console needs and an arcade board does not (Z80, cartridge mapper, SVP,
//  multitap, cheat engine, SRAM banking) is gone, and the C-2 devices take
//  their place.
//
//  Differences from a Mega Drive that matter, all from MAME 0.276 segac2.cpp:
//
//   * 68000 runs at XL2/6, not XL2/7.
//   * The VDP's internal CRAM is bypassed; colours come from 2048 words of
//     external RAM addressed partly by the protection chip (c2_palette.sv).
//   * The interrupt wiring is rearranged.  The VDP line that drives the Z80
//     interrupt on a Mega Drive is the main interrupt here (level 6); the line
//     that normally drives level 6 is not connected at all.  H-int is level 4
//     and the YM3438 timer is level 2.
//   * Sound is a YM3438 and a uPD7759, with the VDP's own PSG still present.
//   * Work RAM is 64 KB at 0xE00000 and is battery backed.
//============================================================================

module c2_system
(
	input             RESET_N,
	input             MCLK,            // 53.693175 MHz (XL2)

	input             LOADING,
	input             PAUSE_EN,

	// ---- per-game configuration, all of it derived from the ROM stream ----
	input       [7:0] IO_DIR_OVERRIDE, // 0xFF except tfrceacjpb (0x0F)
	input       [1:0] PCM_BANK_MASK,   // (upd region size / 0x20000) - 1
	input             HAS_PCM,         // C-2 board; a System C board has none

	// ---- 68000 program ROM ----
	output     [23:1] ROM_ADDR,
	input      [15:0] ROM_DATA,
	output reg        ROM_REQ,
	input             ROM_ACK,

	// ---- uPD7759 sample ROM ----
	output     [18:0] PCM_ADDR,
	input       [7:0] PCM_DATA,
	output            PCM_REQ,
	input             PCM_ACK,

	// ---- protection table load (ROM stream region 2) ----
	input             PROT_WR,
	input       [7:0] PROT_A,
	input       [3:0] PROT_D,

	// ---- video ----
	output      [7:0] RED,
	output      [7:0] GREEN,
	output      [7:0] BLUE,
	output            HS,
	output            VS,
	output            HBL,
	output            VBL,
	output            CE_PIX,
	output      [1:0] RESOLUTION,
	output            INTERLACE,
	output            FIELD,

	// ---- audio ----
	output signed [15:0] AUDIO_L,
	output signed [15:0] AUDIO_R,

	// ---- controls ----
	input       [7:0] P1,
	input       [7:0] P2,
	input       [7:0] SERVICE,
	input       [7:0] DSW1,          // COINAGE
	input       [7:0] DSW2,

	// ---- battery-backed work RAM, for the save file ----
	input      [15:0] BRAM_A,
	input       [7:0] BRAM_DI,
	output      [7:0] BRAM_DO,
	input             BRAM_WE,
	output reg        BRAM_CHANGE,

	// ---- debug ----
	//
	// Explicit outputs rather than hierarchical references from a testbench:
	// a hierarchical tap silently stops matching when the RTL is refactored,
	// and then reports zero for something that is still happening.
	output     [23:0] DBG_M68K_A,
	output     [15:0] DBG_MBUS_DO,
	output            DBG_UNMAPPED,
	output            DBG_BUS_CYCLE,   // one pulse per completed 68000 access
	output            DBG_WRAM_WR,
	output            DBG_VDP_WR,
	output            DBG_PAL_WR,
	output            DBG_PROT_WR,
	output            DBG_IO_WR,
	output            DBG_FM_WR,
	output      [1:0] DBG_FM_A,
	output      [7:0] DBG_FM_D,
	output            DBG_FM_RD,
	output      [7:0] DBG_FM_Q,
	output            DBG_PCM_WR,
	output      [7:0] DBG_PCM_D,
	output            DBG_PSG_WR,
	output      [7:0] DBG_PSG_D,
	output            DBG_IRQ6,
	output            DBG_IRQ4,
	output            DBG_IRQ2,
	output            DBG_DISPLAY_EN,
	output      [5:0] DBG_COL_IDX,
	output            DBG_COL_SPR,
	output      [1:0] DBG_COL_MODE,
	output            DBG_COL_BORDER,
	output     [15:0] DBG_PAL_WDATA,
	output            DBG_INTACK,
	output      [2:0] DBG_IACK_LEVEL,
	output      [2:0] DBG_IPL_N,
	output     [15:0] DBG_PAL_PIXQ,
	output     [10:0] DBG_PAL_PIX_IDX,
	output     [10:0] DBG_PAL_CPU_IDX,
	output            DBG_PAL_STORED_NZ,
	output      [7:0] DBG_IO_PH,
	output      [3:0] DBG_IO_WA,
	output      [7:0] DBG_IO_WD
);

reg reset, hard_reset;
always @(posedge MCLK) if (M68K_CLKENn) begin
	reset      <= ~RESET_N | LOADING;
	hard_reset <= LOADING;
end

//--------------------------------------------------------------
// CLOCK ENABLERS
//
// Everything divides the 53.693175 MHz master.  The 68000 divider is the one
// thing a Mega Drive core gets wrong for this board: /6 here, /7 there.
//--------------------------------------------------------------
wire M68K_CLKEN = M68K_CLKENp;
reg  M68K_CLKENp, M68K_CLKENn;
reg  PSG_CLKEN;
reg  FM_CLKEN;
reg  PCM_CLKEN;

// 640 kHz from 53.693175 MHz is not an integer ratio, and on the real board it
// is a separate crystal (XL1) anyway, so a fractional divider is the honest
// model.  inc = round(640000 * 2^24 / 53693175) = 199978 -> 640007 Hz, 11 ppm.
localparam [23:0] PCM_INC = 24'd199978;
reg [24:0] pcm_acc;

// Declared here rather than inside the always block: a `reg x = 0;` local to a
// procedural block is an initialiser, and Verilator counts it as a blocking
// assignment to a variable that is also assigned non-blocking, which it refuses
// to compile.  Quartus does not care either way.
reg [3:0] FCLKCNT;   // /7  -> YM3438  7.670453 MHz
reg [3:0] VCLKCNT;   // /6  -> 68000   8.948863 MHz
reg [3:0] PCLKCNT;   // /15 -> PSG     3.579545 MHz

always @(negedge MCLK) begin
	if (~RESET_N | LOADING) begin
		VCLKCNT     <= 0;
		PCLKCNT     <= 0;
		FCLKCNT     <= 0;
		PSG_CLKEN   <= 1;
		M68K_CLKENp <= 1;
		M68K_CLKENn <= 1;
		pcm_acc     <= 0;
		PCM_CLKEN   <= 0;
	end
	else begin
		PSG_CLKEN <= 0;
		PCLKCNT   <= PCLKCNT + 1'b1;
		if (PCLKCNT == 14) begin
			PCLKCNT   <= 0;
			PSG_CLKEN <= ~PAUSE_EN;
		end

		M68K_CLKENp <= 0;
		VCLKCNT     <= VCLKCNT + 1'b1;
		if (VCLKCNT == 5) begin
			VCLKCNT     <= 0;
			M68K_CLKENp <= ~PAUSE_EN;
		end

		M68K_CLKENn <= 0;
		if (VCLKCNT == 2) begin
			M68K_CLKENn <= ~PAUSE_EN;
		end

		FM_CLKEN <= 0;
		FCLKCNT  <= FCLKCNT + 1'b1;
		if (FCLKCNT == 6) begin
			FCLKCNT  <= 0;
			FM_CLKEN <= ~PAUSE_EN;
		end

		pcm_acc   <= {1'b0, pcm_acc[23:0]} + PCM_INC;
		PCM_CLKEN <= pcm_acc[24] & ~PAUSE_EN;
	end
end

reg [16:1] ram_rst_a;
always @(posedge MCLK) if (LOADING) ram_rst_a <= ram_rst_a + 1'd1;

//--------------------------------------------------------------
// CPU 68000
//--------------------------------------------------------------
wire [23:1] M68K_A;
wire [15:0] M68K_DO;
wire        M68K_AS_N;
wire        M68K_UDS_N;
wire        M68K_LDS_N;
wire        M68K_RNW;
wire  [2:0] M68K_FC;
wire        M68K_BG_N;
wire        M68K_BGACK_N;

wire        M68K_INTACK = &M68K_FC;
// segac2.cpp int_callback only clears the VDP's pending H-int, and only on a
// level 4 acknowledge.  Decoding the level here rather than passing every
// acknowledge to the VDP keeps a level 6 ack from being swallowed by the
// VDP's serial acknowledge chain.
// The level lives on A[3:1] and is only guaranteed valid while AS is
// asserted; fx68k drives FC=7 a clock before the address settles, so
// decoding on FC alone reads the *previous* cycle's address bits.
wire        M68K_IACK   = M68K_INTACK & ~M68K_AS_N;
wire        VDP_INTACK  = M68K_IACK & (M68K_A[3:1] == 3'd4);

// Level 6: the VDP line that drives the Z80 interrupt on a Mega Drive.  MAME
// asserts it with HOLD_LINE, i.e. it stays up until acknowledged, so latch the
// VDP's self-clearing pulse.
reg  M68K_VINT;
always @(posedge MCLK) begin
	reg old_vint, old_ack;
	if (reset) begin
		M68K_VINT <= 0;
	end
	else begin
		old_vint <= VDP_VINT_T80;
		old_ack  <= M68K_IACK;
		if (~old_vint & VDP_VINT_T80) M68K_VINT <= 1;
		if (~old_ack & M68K_IACK & (M68K_A[3:1] == 3'd6)) M68K_VINT <= 0;
	end
end

wire M68K_HINT  = VDP_HINT;      // level 4, the VDP clears its own pending flag
wire M68K_EXINT = ~FM_IRQ_N;     // level 2, YM3438 timer

reg [2:0] M68K_IPL_N;
always @(posedge MCLK) begin
	reg       old_as;
	reg [1:0] scnt;

	if (reset) M68K_IPL_N <= 3'b111;
	else if (M68K_CLKEN) begin
		old_as <= M68K_AS_N;
		scnt   <= scnt + 1'd1;
		if (~M68K_AS_N) scnt <= 0;
		if ((~old_as & M68K_AS_N) || &scnt) begin
			if      (M68K_VINT)  M68K_IPL_N <= 3'b001;   // level 6
			else if (M68K_HINT)  M68K_IPL_N <= 3'b011;   // level 4
			else if (M68K_EXINT) M68K_IPL_N <= 3'b101;   // level 2
			else                 M68K_IPL_N <= 3'b111;
		end
	end
end

fx68k M68K
(
	.clk(MCLK),
	.extReset(reset),
	.pwrUp(hard_reset),
	.enPhi1(M68K_CLKENp),
	.enPhi2(M68K_CLKENn),

	.eRWn(M68K_RNW),
	.ASn(M68K_AS_N),
	.UDSn(M68K_UDS_N),
	.LDSn(M68K_LDS_N),

	.FC0(M68K_FC[0]),
	.FC1(M68K_FC[1]),
	.FC2(M68K_FC[2]),

	.BGn(M68K_BG_N),
	.BRn(VBUS_BR_N),
	.BGACKn(VBUS_BGACK_N),
	.HALTn(1),

	.DTACKn(M68K_MBUS_DTACK_N),
	.VPAn(~M68K_INTACK),          // all three levels autovector
	.BERRn(1),
	.IPL0n(M68K_IPL_N[0]),
	.IPL1n(M68K_IPL_N[1]),
	.IPL2n(M68K_IPL_N[2]),
	.iEdb(M68K_MBUS_D),
	.oEdb(M68K_DO),
	.eab(M68K_A)
);

assign DBG_M68K_A  = {M68K_A, 1'b0};
assign DBG_MBUS_DO = MBUS_DO;

//--------------------------------------------------------------
// VDP + PSG
//--------------------------------------------------------------
reg         VDP_SEL;
wire [15:0] VDP_DO;
wire        VDP_DTACK_N;

wire [23:1] VBUS_A;
wire        VBUS_SEL;
wire        VBUS_BR_N;
wire        VBUS_BGACK_N;

wire        VDP_HINT;
wire        VDP_VINT_T80;

wire  [5:0] COL_IDX;
wire        COL_SPR;
wire  [1:0] COL_MODE;
wire        COL_BORDER;

wire        vram_req;
wire        vram_we;
wire        vram_u_n;
wire        vram_l_n;
wire [15:1] vram_a;
wire [15:0] vram_d;
wire [15:0] vram_q1, vram_q2;
wire        vram_we_u = vram_we & ~vram_u_n;
wire        vram_we_l = vram_we & ~vram_l_n;

wire        vram32_req;
wire [15:1] vram32_a;
wire [31:0] vram32_q;

dpram #(14) vram_l1
(
	.clock(MCLK),
	.address_a(vram_a[15:2]),
	.data_a(vram_d[7:0]),
	.wren_a(vram_we_l & (vram_ack ^ vram_req) & ~vram_a[1]),
	.q_a(vram_q1[7:0]),

	.enable_a(1'b1),
	.cs_a(1'b1),
	.address_b(LOADING ? ram_rst_a[14:1] : vram32_a[15:2]),
	.data_b(8'h00),
	.enable_b(1'b1),
	.cs_b(1'b1),
	.wren_b(LOADING),
	.q_b(vram32_q[7:0])
);

dpram #(14) vram_u1
(
	.clock(MCLK),
	.address_a(vram_a[15:2]),
	.data_a(vram_d[15:8]),
	.wren_a(vram_we_u & (vram_ack ^ vram_req) & ~vram_a[1]),
	.q_a(vram_q1[15:8]),

	.enable_a(1'b1),
	.cs_a(1'b1),
	.address_b(LOADING ? ram_rst_a[14:1] : vram32_a[15:2]),
	.data_b(8'h00),
	.enable_b(1'b1),
	.cs_b(1'b1),
	.wren_b(LOADING),
	.q_b(vram32_q[15:8])
);

dpram #(14) vram_l2
(
	.clock(MCLK),
	.address_a(vram_a[15:2]),
	.data_a(vram_d[7:0]),
	.wren_a(vram_we_l & (vram_ack ^ vram_req) & vram_a[1]),
	.q_a(vram_q2[7:0]),

	.enable_a(1'b1),
	.cs_a(1'b1),
	.address_b(LOADING ? ram_rst_a[14:1] : vram32_a[15:2]),
	.data_b(8'h00),
	.enable_b(1'b1),
	.cs_b(1'b1),
	.wren_b(LOADING),
	.q_b(vram32_q[23:16])
);

dpram #(14) vram_u2
(
	.clock(MCLK),
	.address_a(vram_a[15:2]),
	.data_a(vram_d[15:8]),
	.wren_a(vram_we_u & (vram_ack ^ vram_req) & vram_a[1]),
	.q_a(vram_q2[15:8]),

	.enable_a(1'b1),
	.cs_a(1'b1),
	.address_b(LOADING ? ram_rst_a[14:1] : vram32_a[15:2]),
	.data_b(8'h00),
	.enable_b(1'b1),
	.cs_b(1'b1),
	.wren_b(LOADING),
	.q_b(vram32_q[31:24])
);

reg vram_ack;
always @(posedge MCLK) vram_ack <= vram_req;

reg vram32_ack;
always @(posedge MCLK) vram32_ack <= vram32_req;

vdp vdp
(
	.RST_N(~reset),
	.CLK(MCLK),

	.SEL(VDP_SEL),
	.A({MBUS_A[4:1], 1'b0}),
	.RNW(MBUS_RNW),
	.DI(MBUS_DO),
	.DO(VDP_DO),
	.DTACK_N(VDP_DTACK_N),

	.vram_req(vram_req),
	.vram_ack(vram_ack),
	.vram_we(vram_we),
	.vram_u_n(vram_u_n),
	.vram_l_n(vram_l_n),
	.vram_a(vram_a),
	.vram_d(vram_d),
	.vram_q(vram_a[1] ? vram_q2 : vram_q1),

	.vram32_req(vram32_req),
	.vram32_ack(vram32_ack),
	.vram32_a(vram32_a),
	.vram32_q(vram32_q),

	.EXINT(),
	.HL(1'b1),

	.HINT(VDP_HINT),
	.VINT_TG68(),
	.INTACK(VDP_INTACK),

	.VINT_T80(VDP_VINT_T80),

	.VBUS_ADDR(VBUS_A),
	.VBUS_DATA(VDP_MBUS_D),
	.VBUS_SEL(VBUS_SEL),
	.VBUS_DTACK_N(VDP_MBUS_DTACK_N),

	.BG_N(M68K_BG_N),
	.BR_N(VBUS_BR_N),
	.BGACK_N(VBUS_BGACK_N),

	.PAL(1'b0),                  // C-2 is NTSC only: 262 lines, 59.92 Hz
	.VRAM_SPEED(1'b1),
	.VSCROLL_BUG(1'b0),
	// BORDER_EN=0 makes HBL/VBL bound the active display exactly, so the core
	// emits H_DISP_WIDTH x V_DISP_HEIGHT and nothing else.  That is what MAME's
	// screen bitmap contains, and comparing a 344x243 bordered frame against a
	// 320x224 one only ever reports SIZE MISMATCH.  An arcade monitor showed
	// the border; MAME's bitmap does not, and MAME is the reference.
	.BORDER_EN(1'b0),
	.CRAM_DOTS(1'b0),
	.OBJ_LIMIT_HIGH_EN(1'b0),

	.FIELD_OUT(FIELD),
	.INTERLACE(INTERLACE),
	.RESOLUTION(RESOLUTION),

	// The internal CRAM path is left connected but its RGB output is unused;
	// C-2 colour comes out of COL_* and through c2_palette.
	.R(),
	.G(),
	.B(),
	.HS(HS),
	.VS(VS),
	.CE_PIX(CE_PIX),
	.HBL(HBL),
	.VBL(VBL),

	.COL_IDX(COL_IDX),
	.COL_SPR(COL_SPR),
	.COL_MODE(COL_MODE),
	.COL_BORDER(COL_BORDER),

	.TRANSP_DETECT(),

	.BGA_EN(1'b1),
	.BGB_EN(1'b1),
	.SPR_EN(1'b1)
);

// PSG lives inside the VDP on a real 315-5313, at VDP offsets 0x10-0x17.
wire signed [10:0] PSG_SND;
jt89 psg
(
	.rst(reset),
	.clk(MCLK),
	.clk_en(PSG_CLKEN),

	.wr_n(MBUS_RNW | ~VDP_SEL | ~MBUS_A[4] | MBUS_A[3]),
	.din(MBUS_DO[15:8]),

	.sound(PSG_SND)
);

//--------------------------------------------------------------
// Sega 315-5296 outputs
//
// Declared here rather than next to the instance because the palette and the
// uPD7759 both consume them and are instantiated earlier in the file.  A net
// used before its declaration is legal Verilog but it is also exactly how an
// implicit one-bit net gets created by accident, and the symptom of that would
// be a palette bank that changes on its own.
//--------------------------------------------------------------
wire [7:0] IO_PD;
wire [7:0] IO_PH;
wire [2:0] IO_CNT;

//--------------------------------------------------------------
// Palette (external colour RAM)
//--------------------------------------------------------------
reg         PAL_SEL;
wire [15:0] PAL_DO;

wire  [1:0] BG_PALBASE;
wire  [1:0] SP_PALBASE;

c2_palette palette
(
	.CLK(MCLK),

	.CPU_SEL(PAL_SEL),
	.CPU_A(MBUS_A[10:1]),
	.CPU_DI(MBUS_DO),
	.CPU_UDS_N(MBUS_UDS_N),
	.CPU_LDS_N(MBUS_LDS_N),
	.CPU_RNW(MBUS_RNW),
	.CPU_DO(PAL_DO),

	.PALBANK(IO_PH[1:0]),
	.BG_PALBASE(BG_PALBASE),
	.SP_PALBASE(SP_PALBASE),
	.ALT_MODE(ALT_PALETTE),

	.COL_IDX(COL_IDX),
	.COL_SPR(COL_SPR),
	.COL_MODE(COL_MODE),
	// control_w bit 0 blanks the whole screen, which Bloxeed uses while it
	// rewrites tiles (segac2.cpp:632, and screen_update_segac2_new fills the
	// bitmap with black when it is clear).  Folding it into the border flag
	// blanks the same pixels the border does.
	.COL_BORDER(COL_BORDER | ~DISPLAY_EN),

	.R(RED),
	.G(GREEN),
	.B(BLUE),

	.DBG_PIXQ(DBG_PAL_PIXQ),
	.DBG_PIX_IDX(DBG_PAL_PIX_IDX),
	.DBG_CPU_IDX(DBG_PAL_CPU_IDX),
	.DBG_STORED_NZ(DBG_PAL_STORED_NZ)
);

//--------------------------------------------------------------
// Protection chip and the control register
//--------------------------------------------------------------
reg        PROT_SEL;
reg        CTRL_SEL;
wire [7:0] PROT_DO;

// control_w, segac2.cpp:628.  Only three bits do anything.
reg        DISPLAY_EN;
reg        ALT_PALETTE;
reg        PROT_FIFO_RESET;

c2_prot prot
(
	.CLK(MCLK),
	.RESET_N(~reset),

	.TBL_WR(PROT_WR),
	.TBL_A(PROT_A),
	.TBL_D(PROT_D),

	.SEL(PROT_SEL),
	.WR(wr_commit & PROT_SEL),
	.DI(M68K_DO[7:0]),
	.DO(PROT_DO),

	.FIFO_RESET(PROT_FIFO_RESET),

	.BG_PALBASE(BG_PALBASE),
	.SP_PALBASE(SP_PALBASE)
);

always @(posedge MCLK) begin
	if (reset) begin
		DISPLAY_EN      <= 0;
		ALT_PALETTE     <= 0;
		PROT_FIFO_RESET <= 0;
	end
	else begin
		PROT_FIFO_RESET <= 0;
		if (wr_commit & CTRL_SEL) begin
			DISPLAY_EN      <= ~M68K_DO[0];      // bit 0 low: display enabled
			PROT_FIFO_RESET <= ~M68K_DO[1];      // bit 1 low: reset the FIFO
			ALT_PALETTE     <= ~M68K_DO[2];      // bit 2 low: alt palette mode
		end
	end
end

//--------------------------------------------------------------
// Sega 315-5296 I/O
//--------------------------------------------------------------
reg        IO_SEL;
wire [7:0] IO_DO;

c2_io io
(
	.CLK(MCLK),
	.RESET_N(~reset),

	.SEL(IO_SEL),
	.WR(wr_commit & IO_SEL),
	.A(MBUS_A[4:1]),          // 68000 word offset = 315-5296 register index
	.RNW(MBUS_RNW),
	.DI(M68K_DO[7:0]),
	.DO(IO_DO),

	.DIR_OVERRIDE(IO_DIR_OVERRIDE),

	.PA_I(P1),
	.PB_I(P2),
	// D7 is the MB3773P watchdog output, D6 the uPD7759 /BUSY (segac2.cpp:559).
	.PC_I({1'b1, PCM_BUSY_N, 6'b111111}),
	.PE_I(SERVICE),
	.PF_I(DSW1),
	.PG_I(DSW2),

	.PD_O(IO_PD),
	.PH_O(IO_PH),
	.CNT_O(IO_CNT)
);

//--------------------------------------------------------------
// YM3438
//--------------------------------------------------------------
reg         FM_SEL;
wire  [7:0] FM_DO;
wire        FM_IRQ_N;
wire signed [15:0] FM_L, FM_R;
wire        FM_SAMPLE;

// The 68000 bus cycle is over long before the YM3438's own 7.67 MHz clock
// enable comes round, so latch the write and hold it for three chip clocks --
// the same shape the Genesis core gets for free from the Z80 bus cycle being
// slower than the FM clock.
reg  [1:0] fm_a;
reg  [7:0] fm_d;
reg  [5:0] fm_wr_cnt;
always @(posedge MCLK) begin
	if (reset) begin
		fm_wr_cnt <= 0;
		fm_a      <= 0;
		fm_d      <= 0;
	end
	else if (wr_commit & FM_SEL) begin
		fm_a      <= MBUS_A[2:1];
		fm_d      <= M68K_DO[7:0];
		fm_wr_cnt <= 6'd21;
	end
	else if (fm_wr_cnt != 0) begin
		fm_wr_cnt <= fm_wr_cnt - 1'd1;
	end
end

jt12 fm
(
	.rst(reset),
	.clk(MCLK),
	.cen(FM_CLKEN),

	.din(fm_d),
	.addr(fm_a),
	.cs_n(1'b0),
	.wr_n(fm_wr_cnt == 0),

	.dout(FM_DO),
	.irq_n(FM_IRQ_N),

	.en_hifi_pcm(1'b0),
	.ladder(1'b0),          // YM3438, not YM2612: no DAC ladder effect

	.snd_left(FM_L),
	.snd_right(FM_R),
	.snd_sample(FM_SAMPLE)
);

//--------------------------------------------------------------
// uPD7759
//
// Stand-alone mode: the chip fetches its own samples.  A CPU write to
// 0x880000 loads the sample number and pulses /START low then high
// (segac2_upd7759_w, segac2.cpp:434).  I/O CNT1 is the chip's /RESET.
//--------------------------------------------------------------
reg        PCM_SEL;
reg  [7:0] PCM_LATCH;
reg        PCM_STN;
wire       PCM_BUSY_N;
wire [16:0] pcm_rom_addr;    // the chip only ever drives 17 bits
wire        pcm_rom_cs;
wire signed [8:0] PCM_SND;

always @(posedge MCLK) begin
	reg [3:0] stn_cnt;
	if (reset) begin
		PCM_LATCH <= 0;
		PCM_STN   <= 1;
		stn_cnt   <= 0;
	end
	else begin
		if (wr_commit & PCM_SEL) begin
			PCM_LATCH <= M68K_DO[7:0];
			PCM_STN   <= 0;
			stn_cnt   <= 4'd8;      // a /START pulse wide enough to be seen
		end
		else if (stn_cnt != 0) begin
			if (PCM_CLKEN) stn_cnt <= stn_cnt - 1'd1;
		end
		else begin
			PCM_STN <= 1;
		end
	end
end

// The bank comes from I/O port H bits 3:2, masked by how many banks the loaded
// sample ROM actually has (segac2.cpp:604).  A one-bank set therefore cannot
// address anything outside its own 128 KB.
wire [1:0] pcm_bank = IO_PH[3:2] & PCM_BANK_MASK;
assign PCM_ADDR = {pcm_bank, pcm_rom_addr};
assign PCM_REQ  = pcm_rom_cs & HAS_PCM;

jt7759 pcm
(
	.rst(reset | ~IO_CNT[1]),
	.clk(MCLK),
	.cen(PCM_CLKEN),
	.stn(PCM_STN),
	.cs(HAS_PCM),
	.mdn(1'b1),                 // stand-alone mode
	.busyn(PCM_BUSY_N),

	.wrn(1'b1),
	.din(PCM_LATCH),
	.drqn(),

	.rom_cs(pcm_rom_cs),
	.rom_addr(pcm_rom_addr),
	.rom_data(PCM_DATA),
	.rom_ok(PCM_ACK),

	.sound(PCM_SND)
);

//--------------------------------------------------------------
// Audio mix
//
// A shift is a claim about a chip core's output scale, so state them.  jt12's
// snd_left is the raw sum of six 9-bit saturating channel accumulators
// (jt12_acc.v:120 sign-extends a signed [8:0], jt12_top.v:588 adds six), so it
// spans only +-1530 -- 4.7% of a 16-bit word -- and has to be scaled to reach
// the DAC.  Mixing it unscaled is what buried the FM under the PSG.
//
// The numbers are upstream Genesis's (Genesis_MiSTer rtl/system.sv:1410-1432):
// x22.25 on the FM, and 1/32 off the PSG before its <<3.  They transfer because
// this is the same jt12 + jt89 pair under the same weights: segac2.cpp routes
// the FM at 0.50 (:1912) and the VDP at 0.50 (:1893) with 315_5313.cpp:248
// putting SEGAPSG into the VDP at 0.50 -- the megadriv values, unchanged.  Do
// not read those weights as a peak ratio; each MAME device normalises its own
// output differently, which is why the ratio here comes from a mix that was
// tuned against hardware rather than from arithmetic on the route numbers.
//
// The uPD7759 goes in at MAME's weight for it, equal to the FM (:1925 0.50
// against :1912 0.50).  PCM_SND is signed 9-bit, so <<7 puts its +-255 at
// +-32640 -- also the scale jt7759's own reference dump uses (jt7759.v:136).
//
// Peaks: FM +-34042 (clamped), PSG +-7905, PCM +-32640.
//--------------------------------------------------------------
wire signed [21:0] fm_x    = {{6{FM_L[15]}}, FM_L};
wire signed [21:0] fm_ext  = (fm_x <<< 4) + (fm_x <<< 2) + (fm_x <<< 1) + (fm_x >>> 2);

wire signed [10:0] psg_adj = PSG_SND - (PSG_SND >>> 5);
wire signed [21:0] psg_ext = {{8{psg_adj[10]}}, psg_adj, 3'b000};

wire signed [21:0] pcm_ext = {{6{PCM_SND[8]}},  PCM_SND, 7'b0000000};

function automatic signed [15:0] clamp(input signed [21:0] v);
	clamp = (v >  22'sd32767) ?  16'sd32767 :
	        (v < -22'sd32768) ? -16'sd32768 : v[15:0];
endfunction

// The board is mono, and only the YM3438's left output reaches the amplifier:
// segac2.cpp:1912 routes output 0 alone and the line below it says "right
// channel not connected".  A game that pans a channel hard right goes silent on
// this hardware, so summing both outputs here would be louder than the board
// and would hide that.  FM_R is left unread deliberately.
wire signed [21:0] mix = fm_ext + psg_ext + pcm_ext;

assign AUDIO_L = clamp(mix);
assign AUDIO_R = clamp(mix);

//--------------------------------------------------------------
// 68000 program ROM
//--------------------------------------------------------------
assign ROM_ADDR = MBUS_A;

//--------------------------------------------------------------
// Work RAM, 64 KB at 0xE00000, battery backed
//
// Reset fill is 0xFF, not 0x00: borencha has no sound otherwise, because it
// lacks the init code its sibling set has (segac2.cpp:1873).
//--------------------------------------------------------------
reg         RAM_SEL;
wire [15:0] ram68k_q;
wire  [7:0] ram_bram_q_u, ram_bram_q_l;

// Port B does double duty: it fills the RAM with 0xFF while the ROM stream is
// loading, and afterwards it is the save-file port.  The fill is not cosmetic:
// NVRAM(DEFAULT_ALL_1) is what borencha needs to have sound at all, because it
// lacks the init code its sibling set has (segac2.cpp:1873).
wire [14:0] ram_b_addr = LOADING ? ram_rst_a[15:1] : BRAM_A[15:1];
wire  [7:0] ram_b_data = LOADING ? 8'hFF           : BRAM_DI;
wire        ram_b_we_u = LOADING ? 1'b1 : (BRAM_WE & ~BRAM_A[0]);
wire        ram_b_we_l = LOADING ? 1'b1 : (BRAM_WE &  BRAM_A[0]);

dpram_dif #(15,8,15,8) ram68k_u
(
	.clock(MCLK),
	.address_a(MBUS_A[15:1]),
	.data_a(MBUS_DO[15:8]),
	.wren_a(RAM_SEL & ~MBUS_RNW & ~MBUS_UDS_N),
	.q_a(ram68k_q[15:8]),

	.enable_a(1'b1),
	.cs_a(1'b1),
	.enable_b(1'b1),
	.cs_b(1'b1),
	.address_b(ram_b_addr),
	.data_b(ram_b_data),
	.wren_b(ram_b_we_u),
	.q_b(ram_bram_q_u)
);

dpram_dif #(15,8,15,8) ram68k_l
(
	.clock(MCLK),
	.address_a(MBUS_A[15:1]),
	.data_a(MBUS_DO[7:0]),
	.wren_a(RAM_SEL & ~MBUS_RNW & ~MBUS_LDS_N),
	.q_a(ram68k_q[7:0]),

	.enable_a(1'b1),
	.cs_a(1'b1),
	.enable_b(1'b1),
	.cs_b(1'b1),
	.address_b(ram_b_addr),
	.data_b(ram_b_data),
	.wren_b(ram_b_we_l),
	.q_b(ram_bram_q_l)
);

assign BRAM_DO = BRAM_A[0] ? ram_bram_q_l : ram_bram_q_u;

always @(posedge MCLK) begin
	if (LOADING) BRAM_CHANGE <= 0;
	else if (RAM_SEL & ~MBUS_RNW & (~MBUS_UDS_N | ~MBUS_LDS_N)) BRAM_CHANGE <= 1;
end

//--------------------------------------------------------------
// MBUS
//--------------------------------------------------------------
reg        M68K_MBUS_DTACK_N;
reg        VDP_MBUS_DTACK_N;

reg [15:0] M68K_MBUS_D;
reg [15:0] VDP_MBUS_D;

reg [23:1] MBUS_A;
reg [15:0] MBUS_DO;
reg        MBUS_RNW;
reg        MBUS_UDS_N;
reg        MBUS_LDS_N;

reg [15:0] NO_DATA;
reg        unmapped;
assign DBG_UNMAPPED = unmapped;

// A 68000 write only becomes real once the CPU has put its data strobes up,
// which is later in the cycle than AS.  That moment is the single point where
// every byte-wide device latches, and it is also the last cycle in which
// MBUS_A and the *_SEL levels still describe this access.
//
// LDS is part of the condition, not decoration.  Every byte-wide device on
// this board is mapped with umask16(0x00ff): they are wired to D7-D0 and are
// reachable only through the lower byte lane, i.e. at odd addresses.  A byte
// write to the even address of the same word puts the data on D15-D8, where
// the device cannot see it -- MAME's mask drops it, and so must this.
//
// Accepting both lanes is not a small error.  Puyo Puyo writes the even byte
// of the 315-5296's port H register, and taking that as a port H write put
// arbitrary values into the colour RAM bank select: the picture was rendered
// correctly and then looked up in banks 1, 2 and 3, which the game never
// writes.  The whole screen came out black.
wire wr_commit = (mstate == MBUS_FINISH) && (msrc == MSRC_M68K) && ~MBUS_RNW &&
                 ~M68K_LDS_N &&
                 (M68K_AS_N | ~M68K_UDS_N | ~M68K_LDS_N);

reg  [3:0] mstate;
reg        msrc;

localparam MSRC_M68K = 0,
           MSRC_VDP  = 1;

localparam MBUS_IDLE     = 0,
           MBUS_SELECT   = 1,
           MBUS_ROM_READ = 2,
           MBUS_RAM_READ = 3,
           MBUS_VDP_READ = 4,
           MBUS_IO_READ  = 5,
           MBUS_PAL_READ = 6,
           MBUS_DEV_READ = 7,
           MBUS_FINISH   = 8;

//--------------------------------------------------------------
// Address decode
//
// Taken bit for bit from the mirror masks in segac2.cpp:766-782.  A mirror
// mask marks the bits that are DON'T CARE, so the decode is over the bits
// outside it.  Getting this from the byte addresses alone would put the
// protection chip and the control register on top of each other -- they are
// 0x200 apart and A9 is the only thing that separates them.
//
//   prot   800000  mirror 13FDFE  ->  A23 A22 A21 A19 A18 A9 = 1 0 0 0 0 0
//   ctrl   800200  mirror 13FDFE  ->                           1 0 0 0 0 1
//   io     840000  mirror 13FEE0  ->  A23 A22 A21 A19 A18 A8 = 1 0 0 0 1 0
//   ym     840100  mirror 13FEF8  ->                           1 0 0 0 1 1
//   upd    880000  mirror 13FEFE  ->                           1 0 0 1 0 0
//   cnt    880100  mirror 13FEFE  ->                           1 0 0 1 0 1
//   pal    8C0000  mirror 13F000  ->  A23 A22 A21 A19 A18    = 1 0 0 1 1
//   vdp    C00000  mirror 18FF00  ->  A23 A22 A21, A18:16, A7:5 = 110, 000, 000
//   ram    E00000  mirror 1F0000  ->  A23 A22 A21            = 1 1 1
//--------------------------------------------------------------
wire dec_rom  = (MBUS_A[23:21] == 3'b000);
wire dec_8xx  = (MBUS_A[23:21] == 3'b100);
wire dec_prot = dec_8xx & ~MBUS_A[19] & ~MBUS_A[18] & ~MBUS_A[9];
wire dec_ctrl = dec_8xx & ~MBUS_A[19] & ~MBUS_A[18] &  MBUS_A[9];
wire dec_io   = dec_8xx & ~MBUS_A[19] &  MBUS_A[18] & ~MBUS_A[8];
wire dec_ym   = dec_8xx & ~MBUS_A[19] &  MBUS_A[18] &  MBUS_A[8];
wire dec_upd  = dec_8xx &  MBUS_A[19] & ~MBUS_A[18] & ~MBUS_A[8];
wire dec_cnt  = dec_8xx &  MBUS_A[19] & ~MBUS_A[18] &  MBUS_A[8];
wire dec_pal  = dec_8xx &  MBUS_A[19] &  MBUS_A[18];
wire dec_vdp  = (MBUS_A[23:21] == 3'b110) && (MBUS_A[18:16] == 3'd0) && (MBUS_A[7:5] == 3'd0);
wire dec_ram  = (MBUS_A[23:21] == 3'b111);

always @(posedge MCLK) begin
	reg [15:0] data;

	if (reset) begin
		M68K_MBUS_DTACK_N <= 1;
		VDP_MBUS_DTACK_N  <= 1;
		VDP_SEL  <= 0;
		IO_SEL   <= 0;
		PAL_SEL  <= 0;
		PROT_SEL <= 0;
		CTRL_SEL <= 0;
		FM_SEL   <= 0;
		PCM_SEL  <= 0;
		RAM_SEL  <= 0;
		unmapped <= 0;
		mstate   <= MBUS_IDLE;
		MBUS_RNW <= 1;
		NO_DATA  <= 'h4E71;      // NOP, the classic open-bus stand-in
	end
	else begin
		if (M68K_AS_N) M68K_MBUS_DTACK_N <= 1;
		if (~VBUS_SEL) VDP_MBUS_DTACK_N  <= 1;

		case (mstate)
		MBUS_IDLE:
			begin
				// Every select is cleared here, without exception.  IO_SEL was
				// missing from this list, so after the first access to the
				// 315-5296 it stayed asserted for ever and `wr_commit & IO_SEL`
				// then fired on every subsequent 68000 write anywhere in the
				// map -- work RAM, palette, VDP.  The I/O chip latched
				// MBUS_A[4:1] of an unrelated address as its register number
				// and that address's data as the value, which put random bytes
				// into port H, which selected random colour RAM banks, which
				// made the screen black.
				PAL_SEL    <= 0;
				PROT_SEL   <= 0;
				CTRL_SEL   <= 0;
				FM_SEL     <= 0;
				PCM_SEL    <= 0;
				RAM_SEL    <= 0;
				IO_SEL     <= 0;
				VDP_SEL    <= 0;
				unmapped   <= 0;
				MBUS_RNW   <= 1;
				MBUS_UDS_N <= 1;
				MBUS_LDS_N <= 1;

				if (!M68K_AS_N && M68K_MBUS_DTACK_N) begin
					msrc     <= MSRC_M68K;
					MBUS_A   <= M68K_A[23:1];
					data      = NO_DATA;
					MBUS_DO  <= M68K_DO;
					MBUS_RNW <= M68K_RNW;
					mstate   <= MBUS_SELECT;
				end
				else if (VBUS_SEL && VDP_MBUS_DTACK_N) begin
					msrc     <= MSRC_VDP;
					MBUS_A   <= VBUS_A;
					data      = NO_DATA;
					MBUS_DO  <= 0;
					mstate   <= MBUS_SELECT;
				end
			end

		MBUS_SELECT:
			begin
				// Nothing decoded is a lockup on the real board.  Here it just
				// finishes with open-bus data, and is counted, because a core
				// that quietly answers everything hides its own decode bugs.
				mstate   <= MBUS_FINISH;
				unmapped <= 1;

				if (dec_rom) begin
					ROM_REQ  <= ~ROM_ACK;
					unmapped <= 0;
					mstate   <= MBUS_ROM_READ;
				end
				else if (dec_ram) begin
					RAM_SEL  <= 1;
					unmapped <= 0;
					mstate   <= MBUS_RAM_READ;
				end
				else if (dec_vdp) begin
					VDP_SEL  <= 1;
					unmapped <= 0;
					mstate   <= MBUS_VDP_READ;
				end
				else if (dec_pal) begin
					PAL_SEL  <= 1;
					unmapped <= 0;
					mstate   <= MBUS_PAL_READ;
				end
				else if (dec_io) begin
					IO_SEL   <= 1;
					unmapped <= 0;
					mstate   <= MBUS_IO_READ;
				end
				else if (dec_prot) begin
					PROT_SEL <= 1;
					unmapped <= 0;
					mstate   <= MBUS_DEV_READ;
				end
				else if (dec_ym) begin
					FM_SEL   <= 1;
					unmapped <= 0;
					mstate   <= MBUS_DEV_READ;
				end
				else if (dec_ctrl) begin
					CTRL_SEL <= 1;
					unmapped <= 0;
					data      = NO_DATA;
					mstate   <= MBUS_FINISH;
				end
				else if (dec_upd) begin
					PCM_SEL  <= 1;
					unmapped <= 0;
					data      = NO_DATA;
					mstate   <= MBUS_FINISH;
				end
				else if (dec_cnt) begin
					// Coin/time bookkeeping chip.  Write only, and nothing in
					// the driver reads it back, so acknowledging is enough.
					unmapped <= 0;
					data      = NO_DATA;
					mstate   <= MBUS_FINISH;
				end
			end

		MBUS_ROM_READ:
			if (ROM_REQ == ROM_ACK) begin
				data    = ROM_DATA;
				if (msrc == MSRC_M68K) NO_DATA <= ROM_DATA;
				mstate <= MBUS_FINISH;
			end

		MBUS_RAM_READ:
			begin
				data    = ram68k_q;
				if (msrc == MSRC_M68K) NO_DATA <= ram68k_q;
				mstate <= MBUS_FINISH;
			end

		MBUS_PAL_READ:
			begin
				data    = PAL_DO;
				if (msrc == MSRC_M68K) NO_DATA <= PAL_DO;
				mstate <= MBUS_FINISH;
			end

		MBUS_VDP_READ:
			if (~VDP_DTACK_N) begin
				VDP_SEL <= 0;
				data     = VDP_DO;
				if (MBUS_A[4:2] == 1) data[15:10] = NO_DATA[15:10];  // unused status bits
				else if (MBUS_A[4]) data = NO_DATA;                  // PSG / debug
				mstate  <= MBUS_FINISH;
			end

		MBUS_IO_READ:
			begin
				// All the byte devices sit on D7-D0 (umask16(0x00ff)), so the
				// high half is whatever was last on the bus.
				data    = {NO_DATA[15:8], IO_DO};
				mstate <= MBUS_FINISH;
			end

		MBUS_DEV_READ:
			begin
				data    = {NO_DATA[15:8], PROT_SEL ? PROT_DO : FM_DO};
				mstate <= MBUS_FINISH;
			end

		MBUS_FINISH:
			begin
				case (msrc)
				MSRC_M68K:
					begin
						M68K_MBUS_D       <= data;
						M68K_MBUS_DTACK_N <= 0;
						// Wait for the 68000 to put its data strobes up before
						// letting a write commit; that is what turns the *_SEL
						// levels into a single write pulse.
						if (M68K_AS_N | MBUS_RNW | ~M68K_UDS_N | ~M68K_LDS_N) begin
							MBUS_DO    <= M68K_DO;
							MBUS_UDS_N <= M68K_UDS_N;
							MBUS_LDS_N <= M68K_LDS_N;
							mstate     <= MBUS_IDLE;
						end
					end

				MSRC_VDP:
					begin
						VDP_MBUS_D       <= data;
						VDP_MBUS_DTACK_N <= 0;
						mstate           <= MBUS_IDLE;
					end
				endcase
			end
		endcase
	end
end

//--------------------------------------------------------------
// Debug taps
//--------------------------------------------------------------
assign DBG_BUS_CYCLE  = (mstate == MBUS_FINISH) && (msrc == MSRC_M68K) &&
                        M68K_MBUS_DTACK_N;
assign DBG_WRAM_WR    = RAM_SEL & ~MBUS_RNW & (~MBUS_UDS_N | ~MBUS_LDS_N);
assign DBG_VDP_WR     = VDP_SEL & ~MBUS_RNW;
assign DBG_PAL_WR     = PAL_SEL & ~MBUS_RNW & (~MBUS_UDS_N | ~MBUS_LDS_N);
assign DBG_PROT_WR    = wr_commit & PROT_SEL;
assign DBG_IO_WR      = wr_commit & IO_SEL;
assign DBG_FM_WR      = wr_commit & FM_SEL;
assign DBG_FM_A       = MBUS_A[2:1];
assign DBG_FM_D       = M68K_DO[7:0];
// The sound driver polls the YM3438 status before nearly every write --
// MAME's puyo does 5478 reads in 60 frames, getting 0x00 and 0x80.  A
// busy flag stuck either way stops the driver dead while the rest of the
// game runs on, so the read side is worth watching as closely as the write.
assign DBG_FM_RD      = (mstate == MBUS_DEV_READ) & FM_SEL & MBUS_RNW;
assign DBG_FM_Q       = FM_DO;
assign DBG_PCM_WR     = wr_commit & PCM_SEL;
assign DBG_PCM_D      = M68K_DO[7:0];
// The PSG has no chip select of its own: it lives at VDP offsets
// 0x10-0x17 and takes the high byte.  Same decode the jt89 instance uses.
assign DBG_PSG_WR     = VDP_SEL & ~MBUS_RNW & MBUS_A[4] & ~MBUS_A[3];
assign DBG_PSG_D      = MBUS_DO[15:8];
assign DBG_IRQ6       = M68K_VINT;
assign DBG_IRQ4       = M68K_HINT;
assign DBG_IRQ2       = M68K_EXINT;
assign DBG_DISPLAY_EN = DISPLAY_EN;
assign DBG_COL_IDX    = COL_IDX;
assign DBG_COL_SPR    = COL_SPR;
assign DBG_COL_MODE   = COL_MODE;
assign DBG_COL_BORDER = COL_BORDER;
assign DBG_PAL_WDATA  = MBUS_DO;
assign DBG_INTACK     = M68K_IACK;
assign DBG_IACK_LEVEL = M68K_A[3:1];
assign DBG_IPL_N      = M68K_IPL_N;
assign DBG_IO_PH      = IO_PH;
assign DBG_IO_WA      = MBUS_A[4:1];
assign DBG_IO_WD      = M68K_DO[7:0];

endmodule
