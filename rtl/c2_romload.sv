//============================================================================
//  ROM stream loader
//
//  The MRA hands the core one byte stream.  Its shape:
//
//      [cfg0][cfg1]                       board config header, 2 bytes
//      then, repeatedly:
//      [region][size23:16][size15:8][size7:0][ size bytes of data ]
//
//  Regions:
//      0  68000 program ROM   -> SDRAM at 0x000000, packed little-endian
//      1  uPD7759 samples     -> SDRAM at 0x200000, byte per byte
//      2  protection table    -> 256 nibbles straight into c2_prot
//
//  Two per-game facts are derived here rather than tabled, because a table
//  indexed by board cannot hold something that varies per set and the sets
//  that share a board are exactly the ones nobody tested:
//
//    HAS_PCM        region 1 is non-empty.  That is the whole difference
//                   between a System C board and a System C-2 board.
//    PCM_BANK_MASK  (region 1 size / 0x20000) - 1.  segac2.cpp:375 takes the
//                   bank count from the declared region size, so ribbit has
//                   four banks even though only the first is dumped -- which
//                   is why c2_rom.py emits the declared size, not the used one.
//
//  The 68000 region is packed as {second byte, first byte}: the loader writes
//  SDRAM little-endian and the 68000 is big-endian, so the MRA swaps each pair
//  and the two swaps cancel.  Get this wrong and the core shows a black screen
//  with no other symptom.
//============================================================================

module c2_romload
(
	input             CLK,
	input             RESET,

	// ---- from hps_io ----
	input             IOCTL_DOWNLOAD,
	input             IOCTL_WR,
	input       [7:0] IOCTL_DOUT,
	output            IOCTL_WAIT,

	// ---- SDRAM write port ----
	output reg [24:1] SDR_ADDR,
	output reg [15:0] SDR_DATA,
	output reg        SDR_REQ,
	input             SDR_ACK,

	// ---- protection table ----
	output reg        PROT_WR,
	output reg  [7:0] PROT_A,
	output reg  [3:0] PROT_D,

	// ---- configuration ----
	output reg  [7:0] BOARD_CFG,
	output reg  [1:0] PCM_BANK_MASK,
	output reg        HAS_PCM,
	output reg        LOADING,
	// Set if a byte ever arrived while an SDRAM write was outstanding.
	output reg        OVERFLOW
);

// A sixty-four byte buffer between the download stream and the SDRAM writes.
//
// IOCTL_WAIT travels out over HPS_BUS and the host takes some cycles to act on
// it, so backpressure cannot be treated as immediate: a byte arriving while an
// SDRAM write is still outstanding must be held, not dropped.  Buffering
// removes the sensitivity rather than tightening the timing -- IOCTL_WAIT means
// "the buffer is half full", giving the host eight bytes of slack to notice it
// in, and OVERFLOW says so if that was ever not enough.
reg  [7:0] fifo[64];
// Initialised at declaration on purpose: the project's .qsf carries
// ALLOW_POWER_UP_DONT_CARE, so a register with no initial value can come out
// of configuration in either state -- and a bogus level here would hold
// IOCTL_WAIT high and stall the download before the first byte.
reg  [6:0] wptr = 0, rptr = 0;
wire [6:0] level      = wptr - rptr;
wire       fifo_empty = (wptr == rptr);
wire       fifo_full  = (level == 7'd64);
wire [7:0] byte_in    = fifo[rptr[5:0]];
// A write is outstanding until the SDRAM acknowledges it.
wire       sdr_busy   = (SDR_REQ != SDR_ACK);
wire       take       = !fifo_empty && !sdr_busy;
// Half full: thirty-two bytes of slack for the host to notice.  The depth is
// margin, not tuning -- the host's real latency is not known, and OVERFLOW
// reports it if this was ever not enough.
assign     IOCTL_WAIT = (level >= 7'd32);

localparam [24:1] BASE_CPU = 24'h000000 >> 1;
localparam [24:1] BASE_PCM = 24'h200000 >> 1;

localparam ST_CFG0   = 0,
           ST_CFG1   = 1,
           ST_REGION = 2,
           ST_SIZE2  = 3,
           ST_SIZE1  = 4,
           ST_SIZE0  = 5,
           ST_DATA   = 6;

reg  [2:0] state;
reg  [3:0] region;
reg [23:0] size;
reg [23:0] count;
reg  [7:0] byte_lo;
reg        have_lo;
reg  [7:0] prot_idx;
reg [23:0] pcm_size;

always @(posedge CLK) begin
	PROT_WR <= 0;

	if (RESET) begin
		state         <= ST_CFG0;
		SDR_REQ       <= 0;
		LOADING       <= 0;
		OVERFLOW      <= 0;
		wptr          <= 0;
		rptr          <= 0;
		BOARD_CFG     <= 0;
		PCM_BANK_MASK <= 0;
		HAS_PCM       <= 0;
		have_lo       <= 0;
		prot_idx      <= 0;
		pcm_size      <= 0;
	end
	else begin
		LOADING <= IOCTL_DOWNLOAD;

		// ---- the incoming byte goes into the FIFO, always ----
		if (IOCTL_WR) begin
			fifo[wptr[5:0]] <= IOCTL_DOUT;
			wptr            <= wptr + 1'd1;
			if (fifo_full) OVERFLOW <= 1;
		end

		if (!IOCTL_DOWNLOAD) begin
			state    <= ST_CFG0;
			have_lo  <= 0;
			prot_idx <= 0;
			wptr     <= 0;
			rptr     <= 0;
		end
		else if (take) begin
			rptr <= rptr + 1'd1;
			case (state)
			ST_CFG0: begin
				BOARD_CFG <= byte_in;
				state     <= ST_CFG1;
			end

			ST_CFG1: state <= ST_REGION;

			ST_REGION: begin
				region  <= byte_in[3:0];
				count   <= 0;
				have_lo <= 0;
				state   <= ST_SIZE2;
			end

			ST_SIZE2: begin size[23:16] <= byte_in; state <= ST_SIZE1; end
			ST_SIZE1: begin size[15:8]  <= byte_in; state <= ST_SIZE0; end

			ST_SIZE0: begin
				size[7:0] <= byte_in;
				// A zero-length region is skipped, not waited for.
				state <= ({size[23:8], byte_in} == 24'd0) ? ST_REGION : ST_DATA;
				if (region == 4'd1) begin
					pcm_size <= {size[23:8], byte_in};
					HAS_PCM  <= ({size[23:8], byte_in} != 24'd0);
					// banks = size / 0x20000, mask = banks - 1.  Only 1, 2 and
					// 4 banks occur; anything else clamps to what fits.
					case ({size[23:8], byte_in})
						24'h020000: PCM_BANK_MASK <= 2'b00;
						24'h040000: PCM_BANK_MASK <= 2'b01;
						24'h080000: PCM_BANK_MASK <= 2'b11;
						default:    PCM_BANK_MASK <= ({size[23:8], byte_in} > 24'h080000)
						                             ? 2'b11 : 2'b00;
					endcase
				end
			end

			ST_DATA: begin
				count <= count + 1'd1;
				if (count + 1'd1 == size) state <= ST_REGION;

				case (region)
				4'd0: begin
					// 68000 program ROM, two stream bytes to one SDRAM word
					if (!have_lo) begin
						byte_lo <= byte_in;
						have_lo <= 1;
					end
					else begin
						SDR_ADDR   <= BASE_CPU + count[23:1];
						SDR_DATA   <= {byte_in, byte_lo};
						SDR_REQ    <= ~SDR_ACK;
						have_lo    <= 0;
					end
				end

				4'd1: begin
					// uPD7759 samples, one byte per SDRAM byte lane
					if (!have_lo) begin
						byte_lo <= byte_in;
						have_lo <= 1;
					end
					else begin
						SDR_ADDR   <= BASE_PCM + count[23:1];
						SDR_DATA   <= {byte_in, byte_lo};
						SDR_REQ    <= ~SDR_ACK;
						have_lo    <= 0;
					end
				end

				4'd2: begin
					// protection table, one nibble per byte
					PROT_A   <= prot_idx;
					PROT_D   <= byte_in[3:0];
					PROT_WR  <= 1;
					prot_idx <= prot_idx + 1'd1;
				end

				default: ;   // unknown region: consumed and dropped
				endcase
			end

			default: state <= ST_REGION;
			endcase
		end
	end
end

endmodule
