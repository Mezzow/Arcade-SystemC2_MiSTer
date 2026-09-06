//============================================================================
//  Sega System C / C-2 for MiSTer
//
//  Derived from Genesis_MiSTer (Sorgelig, Gyorgy Szombathelyi and others),
//  which supplies the 315-5313 VDP, the 68000/VDP bus arbitration, the PLL,
//  the SDRAM controller and the framework in sys/.  Full credits are in
//  README.md.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//============================================================================

module emu
(
	//Master input clock
	input         CLK_50M,

	//Async reset from top-level module.
	//Can be used as initial reset.
	input         RESET,

	//Must be passed to hps_io module
	inout  [48:0] HPS_BUS,

	//Base video clock. Usually equals to CLK_SYS.
	output        CLK_VIDEO,

	//Multiple resolutions are supported using different CE_PIXEL rates.
	//Must be based on CLK_VIDEO
	output        CE_PIXEL,

	//Video aspect ratio for HDMI. Most retro systems have ratio 4:3.
	//if VIDEO_ARX[12] or VIDEO_ARY[12] is set then [11:0] contains scaled size instead of aspect ratio.
	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,

	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,    // = ~(VBlank | HBlank)
	output        VGA_F1,
	output [1:0]  VGA_SL,
	output        VGA_SCALER, // Force VGA scaler
	output        VGA_DISABLE, // analog out is off

	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,

`ifdef MISTER_FB
	// Use framebuffer in DDRAM
	// FB_FORMAT:
	//    [2:0] : 011=8bpp(palette) 100=16bpp 101=24bpp 110=32bpp
	//    [3]   : 0=16bits 565 1=16bits 1555
	//    [4]   : 0=RGB  1=BGR (for 16/24/32 modes)
	//
	// FB_STRIDE either 0 (rounded to 256 bytes) or multiple of pixel size (in bytes)
	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output [11:0] FB_WIDTH,
	output [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,

`ifdef MISTER_FB_PALETTE
	// Palette control for 8bit modes.
	// Ignored for other video modes.
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,
`endif
`endif

	output        LED_USER,  // 1 - ON, 0 - OFF.

	// b[1]: 0 - LED status is system status OR'd with b[0]
	//       1 - LED status is controled solely by b[0]
	// hint: supply 2'b00 to let the system control the LED.
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,

	// I/O board button press simulation (active high)
	// b[1]: user button
	// b[0]: osd button
	output  [1:0] BUTTONS,

	input         CLK_AUDIO, // 24.576 MHz
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,   // 1 - signed audio samples, 0 - unsigned
	output  [1:0] AUDIO_MIX, // 0 - no mix, 1 - 25%, 2 - 50%, 3 - 100% (mono)

	//ADC
	inout   [3:0] ADC_BUS,

	//SD-SPI
	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	//High latency DDR3 RAM interface
	//Use for non-critical time purposes
	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	//SDRAM interface with lower latency
	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE,

`ifdef MISTER_DUAL_SDRAM
	//Secondary SDRAM
	//Set all output SDRAM_* signals to Z ASAP if SDRAM2_EN is 0
	input         SDRAM2_EN,
	output        SDRAM2_CLK,
	output [12:0] SDRAM2_A,
	output  [1:0] SDRAM2_BA,
	inout  [15:0] SDRAM2_DQ,
	output        SDRAM2_nCS,
	output        SDRAM2_nCAS,
	output        SDRAM2_nRAS,
	output        SDRAM2_nWE,
`endif

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,

	// Open-drain User port.
	// 0 - D+/RX
	// 1 - D-/TX
	// 2..6 - USR2..USR6
	// Set USER_OUT to 1 to read from USER_IN.
	input   [6:0] USER_IN,
	output  [6:0] USER_OUT,

	input         OSD_STATUS
);

//////////////////////////////////////////////////////////////////////////////
// Framework tie-offs
//////////////////////////////////////////////////////////////////////////////
assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign BUTTONS   = 0;
// Lit while the ROM stream is coming in, and then held on for the rest of the
// session if the loader ever overflowed.  c2_romload buffers the stream and
// raises OVERFLOW if a byte arrived that it could not hold -- which means the
// ROM image in SDRAM is short and everything after it is undefined.  That
// alarm used to be connected in the testbench only, i.e. in the one place it
// cannot fire: the bench feeds the loader from a file, hardware feeds it from
// the HPS at a latency nobody has measured.  A stuck user LED after a load is
// worth more than a signal that is unreachable on the machine it guards.
assign LED_USER  = ioctl_download | ldr_overflow;
assign LED_DISK  = 0;
assign LED_POWER = 0;
assign VGA_F1    = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign AUDIO_S   = 1;      // signed
assign AUDIO_MIX = 0;

// DDR3 is unused: everything fits in SDRAM and block RAM.
assign DDRAM_CLK      = 0;
assign DDRAM_BURSTCNT = 0;
assign DDRAM_ADDR     = 0;
assign DDRAM_RD       = 0;
assign DDRAM_DIN      = 0;
assign DDRAM_BE       = 0;
assign DDRAM_WE       = 0;

//////////////////////////////////////////////////////////////////////////////
// Options
//////////////////////////////////////////////////////////////////////////////
`include "build_id.v"
localparam CONF_STR = {
	"SystemC2;;",
	"-;",
	"O[2:1],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[5:3],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"-;",
	// "Save <device>" is how the sibling arcade cores name this and the board
	// calls the device backup RAM -- BACKUP RAM CLEAR is its own service menu
	// item.  On,Off so the default is on, matching Arcade-TaitoB.sv:79.
	"O[6],Save Backup RAM,On,Off;",
	"-;",
	"DIP;",
	"-;",
	"R[20],Enter Service Mode;",
	"-;",
	"R[0],Reset;",
	"J1,Button 1,Button 2,Button 3,Start,Coin,Service,Test;",
	"jn,A,B,X,Start,Select,R,L;",
	"V,v",`BUILD_DATE
};

wire [127:0] status;
wire   [1:0] buttons;
wire  [31:0] joystick_0, joystick_1;
wire         forced_scandoubler;
wire  [21:0] gamma_bus;
wire  [15:0] sdram_sz;

wire         ioctl_download;
wire         ioctl_wr;
wire  [24:0] ioctl_addr;
wire   [7:0] ioctl_dout;
wire   [7:0] ioctl_index;
wire         ioctl_wait;

// The ioctl index the MRA's <nvram> tag declares for the backup RAM.  Index 0
// is the ROM stream and 254 the DIP block; everything else is free, and 2 is
// what the arcade cores conventionally use.
localparam [7:0] NVRAM_INDEX = 8'd2;

// Backup RAM upload, driven below.  hps_io declares ioctl_index [15:0] and this
// core narrows it to [7:0], so every comparison against it masks rather than
// testing the whole vector.
wire         ioctl_upload;
wire         ioctl_upload_req;
wire   [7:0] ioctl_upload_index = NVRAM_INDEX;
wire   [7:0] ioctl_din;
wire         ioctl_rd;

hps_io #(.CONF_STR(CONF_STR), .WIDE(0)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),

	.buttons(buttons),
	.forced_scandoubler(forced_scandoubler),

	.status(status),
	// No menu item is hidden, so nothing is masked.  This used to be
	// {|status[2:1]} against an "H0" on the Aspect ratio line, which is the
	// item's own value: selecting anything but Original set the bit that hid
	// the item that sets the bit, and it stayed hidden until the core was
	// reloaded.  Both halves came from the MiSTer arcade template, where H0
	// there is gated on direct_video -- which this core does not use.
	.status_menumask(0),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),

	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(ioctl_upload_req),
	.ioctl_upload_index(ioctl_upload_index),
	.ioctl_din(ioctl_din),
	.ioctl_rd(ioctl_rd),

	.gamma_bus(gamma_bus),
	.sdram_sz(sdram_sz)
);

//////////////////////////////////////////////////////////////////////////////
// Clocks
//
// The PLL is Genesis_MiSTer's, and it powers up in whatever mode its .mif
// holds; the console core reconfigures it for NTSC or PAL at run time.  A C-2
// board is NTSC only (segac2.cpp sets is_pal(false) and 262 lines), so the
// same reconfiguration runs once, unconditionally, and never again.
//////////////////////////////////////////////////////////////////////////////
wire clk_sys, clk_ram, locked;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_ram),
	.reconfig_to_pll(reconfig_to_pll),
	.reconfig_from_pll(reconfig_from_pll),
	.locked(locked)
);

wire [63:0] reconfig_to_pll;
wire [63:0] reconfig_from_pll;
wire        cfg_waitrequest;
reg         cfg_write;
reg   [5:0] cfg_address;
reg  [31:0] cfg_data;

pll_cfg pll_cfg
(
	.mgmt_clk(CLK_50M),
	.mgmt_reset(0),
	.mgmt_waitrequest(cfg_waitrequest),
	.mgmt_read(0),
	.mgmt_readdata(),
	.mgmt_write(cfg_write),
	.mgmt_address(cfg_address),
	.mgmt_writedata(cfg_data),
	.reconfig_to_pll(reconfig_to_pll),
	.reconfig_from_pll(reconfig_from_pll)
);

// The PLL is left at the setting its .mif ships, which is NTSC -- the only
// mode this board has.  Genesis_MiSTer runs this sequence *only* when PAL
// changes, never at power-up; this core started it unconditionally at
// power-up, which reconfigures a PLL that is already correct and takes it out
// of lock while it happens.  Everything downstream of clk_ram is the SDRAM
// controller, and a controller clocked wrong still cycles and still
// acknowledges -- it just returns the wrong data.  Left instantiated because
// the .qip expects it; simply never triggered.
always @(posedge CLK_50M) begin
	reg [2:0] state = 0;

	cfg_write <= 0;
	if (!cfg_waitrequest) begin
		if (state) state <= state + 1'd1;
		case (state)
			1: begin cfg_address <= 0; cfg_data <= 0;          cfg_write <= 1; end
			5: begin cfg_address <= 7; cfg_data <= 2537930535; cfg_write <= 1; end  // NTSC
			7: begin cfg_address <= 2; cfg_data <= 0;          cfg_write <= 1; end
		endcase
	end
end

wire reset = RESET | status[0] | buttons[1] | ioctl_download;

//////////////////////////////////////////////////////////////////////////////
// ROM stream
//
// Index 0 is the MRA's unified stream, parsed by c2_romload.  Index 254 is
// the DIP switch block the MRA's <switches> section produces; the framework
// sends it as eight bytes, and the first two are the two ports this board has.
// Index 2 is the backup RAM, declared by the MRA's <nvram> tag; see below.
//////////////////////////////////////////////////////////////////////////////
wire rom_download = ioctl_download && (ioctl_index == 8'd0);

reg [7:0] dip_sw[8];
initial for (int i = 0; i < 8; i++) dip_sw[i] = 8'hFF;
always @(posedge clk_sys) begin
	if (ioctl_wr && (ioctl_index == 8'd254) && !ioctl_addr[24:3])
		dip_sw[ioctl_addr[2:0]] <= ioctl_dout;
end

//////////////////////////////////////////////////////////////////////////////
// Backup RAM save and restore
//
// All 64 KB of work RAM at 0xE00000 is battery backed on the board
// (segac2.cpp:775 shares it as "nvram"), so a cabinet that has been switched on
// before starts from the previous session rather than from any constant.  The
// MRA declares <nvram index="2" size="65536"/>, so the firmware downloads the
// saved bytes at that index on load and reads them back on an upload request.
//
// c2_system's port B is the save port and already maps one for one: BRAM_A is a
// flat byte address over exactly 64 KB and BRAM_A[0] picks the byte lane, so
// file byte N is the 68000 byte at 0xE00000 + N -- the same layout MAME writes.
//
// Ordering matters and is not an accident.  The power-on fill owns port B for
// the whole of LOADING and wins unconditionally (c2_system.sv:860), so a
// restore has to land after it.  LOADING follows index 0 only, while `reset`
// above follows ioctl_download for *any* index -- so during the index 2
// download the core is held in reset with LOADING already low and port B free.
// If the firmware ever sent the nvram before the ROM, the fill would erase it;
// that is the first thing to check if a restore silently does nothing.
//
// `nv_dirty` asks for a save once the game has written work RAM and then left
// it alone for a moment.  Requesting on every write would save continuously
// during the game's own RAM initialisation.
//////////////////////////////////////////////////////////////////////////////
wire        nv_is_ours = (ioctl_index[5:0] == NVRAM_INDEX[5:0]);
wire        nv_wr      = ioctl_download & ioctl_wr & nv_is_ours;
wire [15:0] nv_addr    = ioctl_addr[15:0];
wire        bk_ena     = ~status[6];      // "Save Backup RAM,On,Off", so 0 = on

wire        wram_wr;                      // one strobe per 68000 write to work RAM
wire  [7:0] bram_do;

reg  [24:0] nv_idle  = 25'h1ffffff;
reg         nv_dirty = 1'b0;

always @(posedge clk_sys) begin
	if (wram_wr) begin
		nv_idle  <= 25'd0;
		nv_dirty <= 1'b0;
	end
	else if (nv_idle != 25'h1ffffff) begin
		nv_idle  <= nv_idle + 25'd1;
		// about half a second at 53.69 MHz with no further writes
		nv_dirty <= (nv_idle == 25'd26800000);
	end
	else begin
		nv_dirty <= 1'b0;
	end
end

assign ioctl_upload_req = nv_dirty & bk_ena;

// Gated on the index, not fed unconditionally: ioctl_din is shared with every
// other upload the framework might run, and driving it for all of them would
// hand them this RAM's contents.
assign ioctl_din = nv_is_ours ? bram_do : 8'd0;

wire [24:1] ldr_addr;
wire [15:0] ldr_data;
wire        ldr_req;
wire        ldr_ack;

wire        prot_wr;
wire  [7:0] prot_a;
wire  [3:0] prot_d;
wire  [7:0] board_cfg;
wire  [1:0] pcm_bank_mask;
wire  [7:0] io_dir_override;
wire  [7:0] nvram_fill;
wire        ldr_overflow;
wire        has_pcm;
wire        loading;

c2_romload romload
(
	.CLK(clk_sys),
	// Never while a ROM stream is in flight.  The framework asserts RESET around
	// a core load, so holding the loader in reset for the whole download would
	// leave it having issued not one SDRAM write.  The loader resets itself on
	// the download edges, so the reset is only needed for the idle case.
	.RESET((RESET | status[0]) & ~rom_download),

	.IOCTL_DOWNLOAD(rom_download),
	.IOCTL_WR(ioctl_wr && (ioctl_index == 8'd0)),
	.IOCTL_DOUT(ioctl_dout),
	.IOCTL_WAIT(ioctl_wait),

	.SDR_ADDR(ldr_addr),
	.SDR_DATA(ldr_data),
	.SDR_REQ(ldr_req),
	.SDR_ACK(ldr_ack),

	.PROT_WR(prot_wr),
	.PROT_A(prot_a),
	.PROT_D(prot_d),

	.BOARD_CFG(board_cfg),
	.IO_DIR_OVERRIDE(io_dir_override),
	.NVRAM_FILL(nvram_fill),
	.PCM_BANK_MASK(pcm_bank_mask),
	.HAS_PCM(has_pcm),
	.LOADING(loading),
	.OVERFLOW(ldr_overflow)
);

//////////////////////////////////////////////////////////////////////////////
// SDRAM
//
// Three ports, and the third one is why this controller was kept rather than
// a simpler one: the uPD7759 fetches its own samples continuously while the
// 68000 is running, so the sample ROM cannot share the program port.
//
//   0  ROM loader writes
//   1  68000 program ROM, 16-bit reads at word addresses
//   2  uPD7759 samples, byte reads at 0x200000 + address
//////////////////////////////////////////////////////////////////////////////
wire [23:1] rom_addr;
wire [15:0] rom_data;
wire        rom_req;
wire        rom_ack;

wire [18:0] pcm_addr;
wire [15:0] pcm_word;
wire        pcm_req;
wire        pcm_ack;

// The byte the uPD7759 asked for; the controller reads a word.
reg  pcm_addr0;
always @(posedge clk_sys) if (pcm_req && !pcm_ack) pcm_addr0 <= pcm_addr[0];
wire [7:0] pcm_data = pcm_addr0 ? pcm_word[15:8] : pcm_word[7:0];

// Level request in, toggle request out: jt7759 holds rom_cs until it has the
// byte, the controller wants an edge.
reg  pcm_sdr_req;
wire pcm_sdr_ack;
always @(posedge clk_sys) begin
	reg old_req;
	old_req <= pcm_req;
	if (pcm_req && !old_req) pcm_sdr_req <= ~pcm_sdr_ack;
end
assign pcm_ack = (pcm_sdr_req == pcm_sdr_ack) & pcm_req;

// Must equal c2_romload's BASE_PCM.  A bare literal here is how this went wrong
// before: 23 bits into sdram's `input [24:1] addr2` is zero-extended, which put
// the sample base at byte 0x080000 -- inside the 68000 program ROM -- instead of
// 0x200000, and the uPD7759 read program bytes as sample headers.
localparam [24:1] SDR_PCM_BASE = 24'h200000 >> 1;

sdram sdram
(
	.*,
	.init(~locked),
	.clk(clk_ram),

	.addr0(ldr_addr),
	.din0(ldr_data),
	.dout0(),
	.wrl0(1),
	.wrh0(1),
	.req0(ldr_req),
	.ack0(ldr_ack),

	.addr1({1'b0, rom_addr}),
	.din1(0),
	.dout1(rom_data),
	.wrl1(0),
	.wrh1(0),
	.req1(rom_req),
	.ack1(rom_ack),

	.addr2(SDR_PCM_BASE | {6'd0, pcm_addr[18:1]}),   // samples at byte 0x200000
	.din2(0),
	.dout2(pcm_word),
	.wrl2(0),
	.wrh2(0),
	.req2(pcm_sdr_req),
	.ack2(pcm_sdr_ack)
);

//////////////////////////////////////////////////////////////////////////////
// The board
//////////////////////////////////////////////////////////////////////////////
wire  [7:0] red, green, blue;
wire        hs, vs, hblank, vblank, ce_pix;
wire  [1:0] resolution;
wire signed [15:0] audio_l, audio_r;

// Everything the 315-5296 reads is active low.  The bit order is from
// INPUT_PORTS_START(systemc_generic) in segac2.cpp:
//   P1/P2   0 B1, 1 B2, 2 B3, 3 unused, 4 down, 5 up, 6 right, 7 left
//   SERVICE 0 coin1, 1 coin2, 2 test, 3 service1, 4 start1, 5 start2
// MiSTer joystick bits: 0 right, 1 left, 2 down, 3 up, 4.. buttons.
wire [7:0] p1_in = ~{ joystick_0[1],    // left
                      joystick_0[0],    // right
                      joystick_0[3],    // up
                      joystick_0[2],    // down
                      1'b0,
                      joystick_0[6],    // button 3
                      joystick_0[5],    // button 2
                      joystick_0[4] };  // button 1

wire [7:0] p2_in = ~{ joystick_1[1],
                      joystick_1[0],
                      joystick_1[3],
                      joystick_1[2],
                      1'b0,
                      joystick_1[6],
                      joystick_1[5],
                      joystick_1[4] };

// The TEST switch is momentary (segac2.cpp:824, PORT_SERVICE_NO_TOGGLE), and a
// press of it *latches* the game into the service menu -- ten frames is enough.
// So the OSD item is a trigger, not a toggle: a toggle would hold TEST down for
// as long as you are in the menu, and the menu's own "PUSH TEST BUTTON" could
// then never be obeyed.
//
// Whether MiSTer delivers an R[] item as a short pulse or as a flipped bit is
// not visible from the FPGA side, so fire on *either* edge and use a lockout
// longer than the pulse to swallow the second edge of a rise/fall pair.  That
// yields exactly one TEST press per OSD selection under both conventions.
localparam [24:0] TEST_PULSE_W = 25'd13_423_294;   // 0.25 s @ 53.693175 MHz
localparam [24:0] TEST_LOCKOUT = 25'd26_846_588;   // 0.50 s

reg  [24:0] test_cnt  = 0;
reg  [24:0] test_lock = 0;
reg         test_osd_d = 0;
always @(posedge clk_sys) begin
	test_osd_d <= status[20];
	if ((status[20] ^ test_osd_d) && !(|test_lock)) begin
		test_cnt  <= TEST_PULSE_W;
		test_lock <= TEST_LOCKOUT;
	end else begin
		if (|test_cnt)  test_cnt  <= test_cnt  - 1'd1;
		if (|test_lock) test_lock <= test_lock - 1'd1;
	end
end

wire test_btn = (|test_cnt) | joystick_0[10] | joystick_1[10];

wire [7:0] service_in = ~{ 2'b00,
                           joystick_1[7],                   // start 2
                           joystick_0[7],                   // start 1
                           joystick_0[9] | joystick_1[9],   // service
                           test_btn,                        // test (momentary)
                           joystick_1[8],                   // coin 2
                           joystick_0[8] };                 // coin 1

c2_system c2
(
	.RESET_N(~reset),
	.MCLK(clk_sys),

	.LOADING(loading),
	// Freeze the game while the OSD is open, the way the other arcade cores do.
	// c2_system gates the 68000, PSG, FM and uPD7759 clock enables on this and
	// deliberately leaves the VDP running, so the picture stays live under the
	// menu.  The pause logic has been there since the fork with nothing driving
	// it -- OSD_STATUS is an emu input that was going unread.
	.PAUSE_EN(OSD_STATUS),

	.IO_DIR_OVERRIDE(io_dir_override),
	.NVRAM_FILL(nvram_fill),
	.PCM_BANK_MASK(pcm_bank_mask),
	.HAS_PCM(has_pcm),

	.ROM_ADDR(rom_addr),
	.ROM_DATA(rom_data),
	.ROM_REQ(rom_req),
	.ROM_ACK(rom_ack),

	.PCM_ADDR(pcm_addr),
	.PCM_DATA(pcm_data),
	.PCM_REQ(pcm_req),
	.PCM_ACK(pcm_ack),

	.PROT_WR(prot_wr),
	.PROT_A(prot_a),
	.PROT_D(prot_d),

	.RED(red),
	.GREEN(green),
	.BLUE(blue),
	.HS(hs),
	.VS(vs),
	.HBL(hblank),
	.VBL(vblank),
	.CE_PIX(ce_pix),
	.RESOLUTION(resolution),
	.INTERLACE(),
	.FIELD(),

	.AUDIO_L(audio_l),
	.AUDIO_R(audio_r),

	.P1(p1_in),
	.P2(p2_in),
	.SERVICE(service_in),
	.DSW1(dip_sw[0]),
	.DSW2(dip_sw[1]),

	// The save port.  It reads and writes the same 64 KB the 68000 sees, one
	// byte at a time, addressed by the ioctl stream; the fill still runs during
	// LOADING and a restore lands after it.  BRAM_CHANGE is c2_system's own
	// sticky dirty flag and is left open -- the autosave timer above runs off
	// DBG_WRAM_WR instead, because it needs the per-write strobe to tell "quiet
	// for half a second" from "written at some point since the ROM loaded".
	.BRAM_A(nv_addr),
	.BRAM_DI(ioctl_dout),
	.BRAM_DO(bram_do),
	.BRAM_WE(nv_wr),
	.BRAM_CHANGE(),

	.DBG_M68K_A(),
	.DBG_MBUS_DO(),
	.DBG_UNMAPPED(),
	.DBG_BUS_CYCLE(dbg_bus_cycle),
	.DBG_WRAM_WR(wram_wr),
	.DBG_VDP_WR(dbg_vdp_wr),
	.DBG_PAL_WR(),
	.DBG_PROT_WR(),
	.DBG_IO_WR(),
	.DBG_IO_RD(),
	.DBG_IO_RA(),
	.DBG_IO_Q(),
	.DBG_FM_WR(),
	.DBG_PCM_WR(),
	.DBG_IRQ6(),
	.DBG_IRQ4(),
	.DBG_IRQ2(),
	.DBG_DISPLAY_EN(),
	.DBG_COL_IDX(),
	.DBG_COL_SPR(),
	.DBG_COL_MODE(),
	.DBG_COL_BORDER(),
	.DBG_PAL_WDATA(),
	.DBG_INTACK(),
	.DBG_IACK_LEVEL(),
	.DBG_IPL_N()
);

assign AUDIO_L = audio_l;
assign AUDIO_R = audio_r;

//////////////////////////////////////////////////////////////////////////////
// Video
//////////////////////////////////////////////////////////////////////////////
wire [1:0] ar = status[2:1];
wire [7:0] arx, ary;

// Latched for the whole frame: a game that switches H32/H40 mid-frame would
// otherwise change the aspect ratio in the middle of a picture.
reg [1:0] res;
always @(posedge clk_sys) begin
	reg old_vbl;
	old_vbl <= vblank;
	if (old_vbl & ~vblank) res <= resolution;
end

always_comb begin
	case (res)
		2'b00: begin arx = 8'd64;  ary = 8'd49;  end   // 256 x 224
		2'b01: begin arx = 8'd64;  ary = 8'd49;  end   // 320 x 224
		2'b10: begin arx = 8'd128; ary = 8'd105; end   // 256 x 240
		2'b11: begin arx = 8'd128; ary = 8'd105; end   // 320 x 240
	endcase
end

wire [2:0] scale = status[5:3];
wire [2:0] sl = scale ? scale - 1'd1 : 3'd0;

assign CLK_VIDEO = clk_ram;
assign VGA_SL = sl[1:0];

//////////////////////////////////////////////////////////////////////////////
// Bring-up display
//
// Kept, switched off.  Draws an arbitrary 16-bit value as horizontal bands, one
// per bit, over the top of the picture.  Nothing inside the FPGA can be probed
// from the HPS -- SDRAM is wired to the FPGA and the framework exposes no
// register slave -- so this is the only way a core that will not boot can say
// where it stopped.
//
// Set BRINGUP to 1 and put the wanted state into `bu`.
//////////////////////////////////////////////////////////////////////////////
localparam BRINGUP = 0;

wire dbg_bus_cycle, dbg_vdp_wr;

// A 16-bit sum of every byte of the ROM stream, as MiSTer delivers it.
//
// The MRA is the one thing the simulation never sees: it loads the image
// c2_rom.py builds, and the two are compared by a tool that shares a parse with
// the MRA generator.  That is how a reversed interleave map survived every
// check.  This is the independent measurement -- the sum the *device* receives,
// against the sum of the file on disk:
//     puyo A0EA   columns 9E1E   ribbit C478   ssonicbr C89C
reg [15:0] bu_sum = 0;
always @(posedge clk_sys)
	if (ioctl_wr && !ioctl_index) bu_sum <= bu_sum + {8'd0, ioctl_dout};

reg [7:0] bu = 8'd0;
always @(posedge clk_sys) begin
	reg old_ldr_req, old_ldr_ack, old_rom_ack, old_loading;
	old_ldr_req <= ldr_req;  old_ldr_ack <= ldr_ack;
	old_rom_ack <= rom_ack;  old_loading <= loading;
	if (rom_download)            bu[0] <= 1;
	if (ioctl_wr && !ioctl_index) bu[1] <= 1;
	if (ioctl_wait)              bu[2] <= 1;
	if (ldr_req != old_ldr_req)  bu[3] <= 1;
	if (ldr_ack != old_ldr_ack)  bu[4] <= 1;
	if (old_loading && !loading) bu[5] <= 1;
	if (rom_ack != old_rom_ack)  bu[6] <= 1;
	if (dbg_vdp_wr)              bu[7] <= 1;
end

reg [8:0] bu_x;
always @(posedge clk_sys) begin
	if (hblank)      bu_x <= 0;
	else if (ce_pix) bu_x <= bu_x + 1'd1;
end

reg [4:0] bu_sub;
reg [2:0] bu_band;
always @(posedge clk_sys) begin
	reg old_hbl, old_vbl;
	old_hbl <= hblank;
	old_vbl <= vblank;
	if (old_vbl && !vblank) begin
		bu_sub  <= 0;
		bu_band <= 0;
	end
	else if (hblank && !old_hbl) begin
		if (bu_sub == 5'd27) begin
			bu_sub <= 0;
			if (bu_band != 3'd7) bu_band <= bu_band + 1'd1;
		end
		else bu_sub <= bu_sub + 1'd1;
	end
end

// Top three bands: the eight state bits, as before.  Bottom five: the stream
// checksum drawn as sixteen columns, most significant bit left.
wire [3:0] bu_col = bu_x[7:4];
// Bands 0-3: the eight state bits.  Bands 4-5: the stream checksum.
// Bands 6-7: the two DIP bytes the core actually received, DSW1 then DSW2 --
// the value the game reads, not the value the MRA asked for.
wire       bu_sumrow = (bu_band == 3'd4) || (bu_band == 3'd5);
wire       bu_diprow = (bu_band >= 3'd6);
wire [15:0] bu_dip = {dip_sw[0], dip_sw[1]};
wire bu_lit = bu_diprow ? (bu_dip[15 - bu_col] & (bu_x[3:0] != 4'd15))
            : bu_sumrow ? (bu_sum[15 - bu_col] & (bu_x[3:0] != 4'd15))
                        : (bu[bu_band] & (bu_sub != 5'd27));

wire [7:0] r_out = BRINGUP ? {8{bu_lit}} : red;
wire [7:0] g_out = BRINGUP ? {8{bu_lit}} : green;
wire [7:0] b_out = BRINGUP ? {8{bu_lit}} : blue;

reg old_ce_pix;
always @(posedge CLK_VIDEO) old_ce_pix <= ce_pix;

wire vga_de;

video_mixer #(.LINE_LENGTH(340), .HALF_DEPTH(0), .GAMMA(1)) video_mixer
(
	.*,

	.ce_pix(~old_ce_pix & ce_pix),

	.scandoubler(scale || forced_scandoubler),
	.hq2x(scale == 1),
	.freeze_sync(),

	.VGA_DE(vga_de),
	.R(r_out),
	.G(g_out),
	.B(b_out),

	.HSync(hs),
	.VSync(vs),
	.HBlank(hblank),
	.VBlank(vblank)
);

video_freak video_freak
(
	.*,
	.VGA_DE_IN(vga_de),
	.ARX((!ar) ? arx : (ar - 1'd1)),
	.ARY((!ar) ? ary : 12'd0),
	.CROP_SIZE(10'd0),
	.CROP_OFF(0),
	.SCALE(2'd0)
);

endmodule
