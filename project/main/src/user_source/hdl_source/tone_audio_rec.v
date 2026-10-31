`timescale 1ns/1ps
// tone_audio_rec: 2 s practice recording (8 kHz, G.711 mu-law, 16000 x 8 bit) and playback
// to the HDMI audio path. Everything runs in the video_clk domain.
//
// Recording
//   rec_start (pulse): wr_addr/rec_len <- 0, decimation phase <- 0, aborts an encode in
//     progress, stops playback.
//   While rec_en=1 every mic_valid is counted; the 1st, 3rd, 5th ... are taken (16k -> 8k,
//   no filter). s16 = mic_sample[23:8]; s = sat16(s16 << GAIN_SHIFT); byte = mu-law(s)
//   (Sun g711.c linear2ulaw incl. CLIP=32635). Encoder is serial (<= 9 clocks after the
//   mic_valid it writes the byte at wr_addr and wr_addr++). Stops at REC_MAX bytes.
//   rec_len = number of bytes written.
//   NOTE: the BRAM holds the bit-inverted G.711 byte, ~ulaw = {sign, seg[2:0], mant[3:0]}
//   (saves the 8 inverters on each side); the G.711 byte is ~mem[a].
// Playback
//   play_start (pulse): play_busy <- 1 at once, a start request is armed. The next
//     aud_valid resets the read address and the 6x counter (output unchanged on that
//     aud_valid); from the following aud_valid on each byte is presented on 6 aud_valid's.
//   The output registers (sel_q, out_s16) only change on aud_valid clocks, so the value the
//   HDMI core samples with aud_valid is always one whole sample (the one latched on the
//   previous aud_valid): aud_x = sel_q ? {s16, 8'h00} : tone_x (combinational mux).
//   End: after the 6th presentation of byte rec_len-1 is latched, play_busy <- 0; the next
//   aud_valid switches back to tone. play_stop / rec_start: play_busy <- 0 at once, tone
//   from the next aud_valid on. Priority in one clock: aud_valid update < play_start <
//   play_stop/rec_start.
//   play_frame: 0 on play_start, +1 on each frame_start while play_busy.
//   Decoder: bit-serial, LSB first, 18 clocks after each read address change
//   (s16 = sign ? 132 - t : t - 132, t = {1, mant, 1, 00} << seg).
// Storage: 4 x EG_PHY_BRAM32K, DP16K, DATA_WIDTH 8 (4096 x 8 each). Byte address a[13:0]:
//   block a[13:12], addr = a[11:1], byte = a[0] (8-bit mode pin mapping taken from TD's own
//   EG_LOGIC_BRAM(IMPLEMENT "32K") -> EG_PHY_BRAM32K netlist, write_verilog of TD 6.2.1).
//   Port A = write, port B = read (NOREG, dob[7:0] one clock after addrb/byteb).
// Requirements on the inputs: mic_valid spacing > 10 clocks, aud_valid spacing > 24
//   clocks (real: ~1562 / ~520 at 25 MHz); aud_valid / mic_valid are 1-clock pulses.
// GAIN_SHIFT: not calibrated.
module tone_audio_rec #(
    parameter GAIN_SHIFT = 2,          // not calibrated
    parameter REC_MAX    = 16000
) (
    input  wire        clk,
    input  wire        rst_n,
    // recording
    input  wire        rec_start,
    input  wire        rec_en,
    input  wire        mic_valid,
    input  wire [23:0] mic_sample,
    // playback control
    input  wire        play_start,
    input  wire        play_stop,
    input  wire        frame_start,
    // audio path
    input  wire        aud_valid,
    input  wire [23:0] tone_l,
    input  wire [23:0] tone_r,
    output wire [23:0] aud_l,
    output wire [23:0] aud_r,
    // status
    output reg         play_busy,
    output reg  [6:0]  play_frame,
    output wire tone_selected,
    output wire [13:0] rec_len
);
    // ---------------- recording: serial mu-law encoder ----------------
    reg  [13:0] wr_addr;
    reg         ph;            // decimation phase (0 = take)
    reg         ebusy;
    reg  [14:0] ep;            // |s| + 132, normalised by left shifts
    reg  [2:0]  eseg;
    reg         eneg;

    wire [15:0] s16  = mic_sample[23:8];
    wire [15:0] sh   = s16 << GAIN_SHIFT;
    wire [GAIN_SHIFT:0] top = s16[15 -: GAIN_SHIFT+1];
    wire        sat  = ~(&top | ~|top);
    wire        neg  = s16[15];
    // (sh ^ neg) + 132 + neg = |sh| + 132 ; bit15 set <=> |sh| > 32635 (CLIP)
    wire [15:0] esum = (sh ^ {16{neg}}) + {8'd0, 7'b1000010, neg};
    wire        clip = sat | esum[15];
    wire        full = (wr_addr == REC_MAX[13:0]);
    wire        take = mic_valid & rec_en & ~full;
    wire        we   = ebusy & ep[14];
    wire [7:0]  wbyte = {eneg, eseg, ep[13:10]};      // = ~ulaw

    assign rec_len = wr_addr;

    // address of the last byte written (= rec_len - 1 while rec_len > 0); plain FFs with CE
    reg  [13:0] rec_last;
    always @(posedge clk)
        if (we) rec_last <= wr_addr;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_addr <= 14'd0;
            ph      <= 1'b0;
            ebusy   <= 1'b0;
        end else if (rec_start) begin
            wr_addr <= 14'd0;
            ph      <= 1'b0;
            ebusy   <= 1'b0;
        end else begin
            if (take)
                ph <= ~ph;
            if (take & ~ph)
                ebusy <= 1'b1;
            else if (we) begin
                ebusy   <= 1'b0;
                wr_addr <= wr_addr + 14'd1;
            end
        end
    end

    always @(posedge clk) begin
        if (take & ~ph) begin
            ep   <= clip ? 15'h7FFF : esum[14:0];
            eneg <= neg;
            eseg <= 3'd7;
        end else if (~ep[14]) begin       // also runs when idle (harmless)
            ep   <= {ep[13:0], 1'b0};
            eseg <= eseg - 3'd1;
        end
    end

    // ---------------- storage ----------------
    reg  [13:0] rd_addr;
    wire [31:0] dall;          // dob[7:0] of the 4 blocks

`ifdef SIMULATION
    // Behavioural model of the 4 BRAM32K (TD's simulation model is encrypted).
    reg [7:0] sim_mem [0:16383];
    reg [7:0] sim_dob [0:3];
    integer si;
    always @(posedge clk) begin
        if (we)
            sim_mem[wr_addr] <= wbyte;
        for (si = 0; si < 4; si = si + 1)
            sim_dob[si] <= sim_mem[{si[1:0], rd_addr[11:0]}];
    end
    assign dall = {sim_dob[3], sim_dob[2], sim_dob[1], sim_dob[0]};
`else
    genvar b;
    generate
        for (b = 0; b < 4; b = b + 1) begin : g_blk
            wire [15:0] dob16;
            EG_PHY_BRAM32K #(
                .MODE("DP16K"), .DATA_WIDTH_A("8"), .DATA_WIDTH_B("8"),
                .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
                .WRITEMODE_A("NORMAL"), .WRITEMODE_B("NORMAL"), .SRMODE("SYNC"),
                .CSAMUX("SIG"), .CSBMUX("SIG"), .OCEAMUX("SIG"), .OCEBMUX("SIG"),
                .RSTAMUX("SIG"), .RSTBMUX("SIG"), .CLKAMUX("SIG"), .CLKBMUX("SIG"),
                .WEAMUX("SIG"), .WEBMUX("SIG"), .READBACK("OFF"), .INIT_FILE("")
            ) u_bram (
                .doa(), .dob(dob16),
                .dia({8'd0, wbyte}), .dib(16'd0),
                .addra(wr_addr[11:1]), .addrb(rd_addr[11:1]),
                .bytea(wr_addr[0]), .bytewea(1'b0), .byteb(rd_addr[0]), .byteweb(1'b0),
                .csa(1'b1), .wea(we & (wr_addr[13:12] == b)), .csb(1'b1), .web(1'b0),
                .clka(clk), .rsta(1'b0), .clkb(clk), .rstb(1'b0),
                .ocea(1'b0), .oceb(1'b0)
            );
            assign dall[8*b +: 8] = dob16[7:0];
        end
    endgenerate
`endif

    // rd_addr only changes on aud_valid clocks and is used >= 2 clocks later, so the
    // block select uses rd_addr directly.
    wire [7:0] rbyte = dall[8*rd_addr[13:12] +: 8];

    // ---------------- playback: bit-serial mu-law decoder ----------------
    reg         req;           // play_start armed, waiting for the next aud_valid
    reg         sel_q;         // output select (changes on aud_valid clocks only)
    reg  [15:0] out_s16;       // output sample (changes on aud_valid clocks only)
    reg  [2:0]  cnt6;
    reg  [1:0]  dph;           // 1: BRAM read, 2: load, 3: run 16 bit clocks
    reg  [3:0]  dbit;          // output bit index
    reg  [3:0]  dz;            // leading zero bits of t still to emit (= seg + 2 at load)
    reg  [5:0]  dsh;           // {1, mant, 1} shifted out LSB first, zero fill
    reg         dneg, dbor;
    reg  [15:0] dstage;        // result shift register, filled from the top

    wire [13:0] rd_next = rd_addr + 14'd1;
    wire        tbit = (dz == 4'd0) & dsh[0];
    // C = 132 + neg = 0x84 | neg ; bits 0, 2, 7
    wire        cbit = (dbit == 4'd2) | (dbit == 4'd7) | ((dbit == 4'd0) & dneg);
    wire        dif  = tbit ^ cbit ^ dbor;
    wire        bor  = (~tbit & (cbit | dbor)) | (cbit & dbor);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            play_busy <= 1'b0;
            req       <= 1'b0;
            sel_q     <= 1'b0;
            rd_addr   <= 14'd0;
            cnt6      <= 3'd0;
            dph       <= 2'd0;
            play_frame <= 7'd0;
        end else begin
            if (dph == 2'd1 || dph == 2'd2)
                dph <= dph + 2'd1;
            else if (dph == 2'd3 && dbit == 4'd15)
                dph <= 2'd0;
            if (aud_valid) begin
                if (req) begin
                    req     <= 1'b0;
                    rd_addr <= 14'd0;
                    cnt6    <= 3'd0;
                    dph     <= 2'd1;
                    if (rec_len == 14'd0)
                        play_busy <= 1'b0;
                end else if (play_busy) begin
                    sel_q <= 1'b1;
                    if (cnt6 == 3'd5) begin
                        cnt6    <= 3'd0;
                        rd_addr <= rd_next;
                        dph     <= 2'd1;
                        if (rd_addr == rec_last)      // rd_next == rec_len
                            play_busy <= 1'b0;
                    end else
                        cnt6 <= cnt6 + 3'd1;
                end else
                    sel_q <= 1'b0;
            end
            if (play_start) begin
                play_busy <= 1'b1;
                req       <= 1'b1;
            end
            if (play_stop | rec_start) begin
                play_busy <= 1'b0;
                req       <= 1'b0;
            end
            if (play_start)
                play_frame <= 7'd0;
            else if (frame_start & play_busy)
                play_frame <= play_frame + 7'd1;
        end
    end

    always @(posedge clk) begin
        if (aud_valid & ~req & play_busy)
            out_s16 <= dstage;
        if (dph == 2'd2) begin
            dbit <= 4'd0;
            dbor <= 1'b0;
            dneg <= rbyte[7];
            dz   <= {1'b0, rbyte[6:4]} + 4'd2;
            dsh  <= {1'b1, rbyte[3:0], 1'b1};
        end else if (dph == 2'd3) begin
            dbit   <= dbit + 4'd1;
            dbor   <= bor;
            dstage <= {dif ^ dneg, dstage[15:1]};
            if (dz != 4'd0) dz <= dz - 4'd1;
            else            dsh <= {1'b0, dsh[5:1]};
        end
    end

    assign aud_l = sel_q ? {out_s16, 8'h00} : tone_l;
    assign aud_r = sel_q ? {out_s16, 8'h00} : tone_r;
    assign tone_selected = !sel_q;
endmodule
