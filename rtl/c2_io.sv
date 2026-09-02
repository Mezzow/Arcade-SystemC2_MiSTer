//============================================================================
//  Sega 315-5296 I/O chip
//
//  Eight bidirectional 8-bit ports, a direction register, a CNT register and
//  a four-byte "SEGA" string that games read as a cheap presence check.
//
//  Modelled from MAME 0.276 src/mame/sega/315_5296.cpp.  Register map:
//
//    0x0-0x7  ports A..H.  Reading a port configured as an output returns the
//             last value written to it, not the pin state.
//    0x8-0xB  'S' 'E' 'G' 'A'
//    0xC,0xE  CNT register
//    0xD,0xF  direction register, 1 = output
//    The C-2 map exposes 0x840000-0x84001F, sixteen 68000 words, so only
//    registers 0x0-0xF are reachable on this board.  A is the word offset.
//
//  DIR_OVERRIDE exists for one set: tfrceacjpb writes 0x58 to the direction
//  register, which would make three input ports read back their own output
//  latches.  MAME masks the direction with 0x0F for that set
//  (segac2.cpp:1931).  It affects reads only, exactly as the device does.
//
//  Reset leaves every port an input, so port H reads 0 until the game
//  configures it -- which is what puts colour RAM bank 0 and uPD7759 sample
//  bank 0 in place before any write happens.
//============================================================================

module c2_io
(
	input             CLK,
	input             RESET_N,

	input             SEL,          // address decoded, access in progress
	input             WR,           // one-cycle write strobe from the bus
	input       [3:0] A,            // register index: the 68000 word offset
	input             RNW,
	input       [7:0] DI,
	output reg  [7:0] DO,
	output            DTACK_N,

	input       [7:0] DIR_OVERRIDE, // 0xFF normally

	// inputs
	input       [7:0] PA_I,         // P1
	input       [7:0] PB_I,         // P2
	input       [7:0] PC_I,         // uPD7759 /BUSY in bit 6, watchdog in bit 7
	input       [7:0] PE_I,         // SERVICE
	input       [7:0] PF_I,         // COINAGE  (DSW1)
	input       [7:0] PG_I,         // DSW2

	// outputs
	output      [7:0] PD_O,         // coin meters / lockouts / amplifier mute
	output      [7:0] PH_O,         // [3:2] PCM bank, [1:0] colour RAM A10:A9
	output      [2:0] CNT_O         // CNT0-2; CNT1 is uPD7759 /RESET on C-2
);

reg  [7:0] latch[8];
reg  [7:0] dir;
reg  [7:0] cnt;

// A port only drives its pins while the direction register says output.  The
// pull-ups on the board mean an input-configured output port reads as 0 at the
// far end, which is how MAME models it (it calls the output handler with 0).
assign PD_O  = dir[3] ? latch[3] : 8'h00;
assign PH_O  = dir[7] ? latch[7] : 8'h00;
assign CNT_O = cnt[2:0];

// Purely combinational device: it answers in the same cycle it is selected.
assign DTACK_N = ~SEL;

wire [7:0] port_in[8];
assign port_in[0] = PA_I;
assign port_in[1] = PB_I;
assign port_in[2] = PC_I;
assign port_in[3] = 8'hFF;   // D is an output on C-2; never read as an input
assign port_in[4] = PE_I;
assign port_in[5] = PF_I;
assign port_in[6] = PG_I;
assign port_in[7] = 8'hFF;   // H is an output on C-2

always_comb begin
	DO = 8'hFF;
	case (A)
		4'h0, 4'h1, 4'h2, 4'h3, 4'h4, 4'h5, 4'h6, 4'h7:
			DO = (dir[A[2:0]] & DIR_OVERRIDE[A[2:0]]) ? latch[A[2:0]] : port_in[A[2:0]];
		4'h8: DO = "S";
		4'h9: DO = "E";
		4'hA: DO = "G";
		4'hB: DO = "A";
		4'hC, 4'hE: DO = cnt;
		4'hD, 4'hF: DO = dir;
		default: DO = 8'hFF;
	endcase
end

always @(posedge CLK) begin
	if (!RESET_N) begin
		dir <= 8'h00;        // every port an input after reset
		cnt <= 8'h00;
		for (int i = 0; i < 8; i++) latch[i] <= 8'h00;
	end
	else begin
		if (WR) begin
			case (A)
				4'h0, 4'h1, 4'h2, 4'h3, 4'h4, 4'h5, 4'h6, 4'h7:
					latch[A[2:0]] <= DI;
				4'hE: cnt <= DI;
				4'hF: dir <= DI;
				default: ;
			endcase
		end
	end
end

endmodule
