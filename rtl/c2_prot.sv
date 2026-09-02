//============================================================================
//  Sega System C/C-2 protection chip (317-xxxx, an Altera EPM5032)
//
//  Two things live behind one byte-wide port at 0x800000:
//
//   1. The palette bases.  A write sets bg_palbase = d[1:0] and
//      sp_palbase = d[3:2].  These pick which 64-colour block of the external
//      colour RAM the VDP's background and sprite pixels land in, so the
//      protection chip is on the video path, not just a lock.
//
//   2. A 2-stage FIFO in front of a combinational 8-in/4-out function:
//
//          write d:  index = {wbuf, rbuf}      <- sampled BEFORE the update
//                    wbuf  = d[3:0]
//                    rbuf  = table[index]
//          read:     0xF0 | rbuf
//
//      Note the order.  A write reveals the entry selected by the state the
//      chip was already in; the byte written only chooses the next state's
//      upper nibble.  Getting this backwards produces a core that boots and
//      then hangs somewhere unrelated.
//
//  Every one of the 18 protection functions in segac2.cpp is combinational, so
//  each chip collapses to a 256x4 table.  The table arrives in the ROM stream
//  (region 2) rather than living in a per-game case statement here, which is
//  what lets one build serve all 55 sets -- including the sets with no chip
//  fitted, whose table is all zeros so a read returns 0xF0.
//
//  control_w bit 1 low clears both FIFO stages (segac2.cpp:637).
//============================================================================

module c2_prot
(
	input             CLK,
	input             RESET_N,

	// protection table load, from the ROM stream
	input             TBL_WR,
	input       [7:0] TBL_A,
	input       [3:0] TBL_D,

	input             SEL,          // 0x800000 decoded
	input             WR,           // one-cycle write strobe from the bus
	input       [7:0] DI,
	output      [7:0] DO,
	output            DTACK_N,

	input             FIFO_RESET,   // control_w bit 1 low

	output reg  [1:0] BG_PALBASE,
	output reg  [1:0] SP_PALBASE
);

reg [3:0] table_ram[256];
reg [3:0] wbuf, rbuf;

always @(posedge CLK) if (TBL_WR) table_ram[TBL_A] <= TBL_D;

// The lookup is combinational, and it has to be.  A registered read port needs
// the index a cycle early, and the index is {wbuf, rbuf} as they stand *before*
// the write updates them -- so a pipelined version returns the previous
// lookup, one write behind, for ever.  The symptom is not subtle but it is
// well hidden: the game boots normally, fails its protection check, and jumps
// to a halt loop several thousand instructions away.
//
// 256 x 4 bits is small enough that this costs nothing.
wire [7:0] index    = {wbuf, rbuf};
wire [3:0] table_q  = table_ram[index];

assign DO      = {4'hF, rbuf};
assign DTACK_N = ~SEL;

always @(posedge CLK) begin
	if (!RESET_N) begin
		wbuf       <= 0;
		rbuf       <= 0;
		BG_PALBASE <= 0;
		SP_PALBASE <= 0;
	end
	else begin
		if (FIFO_RESET) begin
			wbuf <= 0;
			rbuf <= 0;
		end
		else if (WR) begin
			BG_PALBASE <= DI[1:0];
			SP_PALBASE <= DI[3:2];
			// Both halves move at once, exactly as prot_w does: the index is
			// the old pair, the result becomes the new rbuf, and the byte
			// written becomes the new wbuf.
			rbuf       <= table_q;
			wbuf       <= DI[3:0];
		end
	end
end

endmodule
