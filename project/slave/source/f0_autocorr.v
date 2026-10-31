`timescale 1ns/1ps
// F0 (fundamental frequency) estimator via windowed autocorrelation.
//
// One frame = FRAME_LEN samples (~16 ms at 16 kHz). Each frame:
//   1. Collect FRAME_LEN samples into a circular buffer.
//   2. Compute R[k] = sum_{n=0}^{N-1} x[n]*x[n-k] for k = LAG_MIN..LAG_MAX
//      using one DSP in serial mode (one multiply-accumulate per clock).
//   3. Find the lag k* with maximum R[k]; f0 = SAMPLE_HZ / k*.
//   4. Gate: if R[0] < VOICED_THR, declare unvoiced (f0_valid = 0).
//   5. Map k* to a 6-bit display code (0 = unvoiced, 1..63 = voiced):
//        code = 63 - (k* - LAG_MIN) * 63 / (LAG_MAX - LAG_MIN)
//      so code 63 = highest pitch (LAG_MIN), code 1 = lowest (LAG_MAX).
//
// Latency: f0_valid/f0_code update once per frame, held until next frame.
// DSP: uses one multiplier (18x18 -> 36 bit); inferred as DSP block by TD.
// BRAM: one 256x16 sample buffer inferred as BRAM (256*16 = 4096 bits -> 1 bram9k).
//
// Parameters (defaults tuned for 16 kHz input):
//   FRAME_LEN   256   ~16 ms; must be power-of-2 <= 256
//   LAG_MIN      32   500 Hz upper bound  (16000/32 = 500)
//   LAG_MAX     200   80  Hz lower bound  (16000/200 = 80)
//   VOICED_THR  512   R[0] threshold; tune after on-board test
module f0_autocorr #(
    parameter integer FRAME_LEN  = 256,
    parameter integer LAG_MIN    = 32,
    parameter integer LAG_MAX    = 200,
    parameter integer VOICED_THR = 512
) (
    input  wire              clk, rst_n,
    input  wire              pcm_valid,           // single-cycle pulse ~16 kHz
    input  wire signed [15:0] pcm_sample,
    output reg               f0_valid,            // 1 = voiced, updated each frame
    output reg  [5:0]        f0_code              // 1..63 pitch code, 0 = unvoiced
);
    localparam integer LAG_RANGE = LAG_MAX - LAG_MIN;   // 168
    localparam integer LOG2_FL   = 8;                   // log2(256)
    localparam integer LOG2_BUF  = 9;                   // 512-sample buffer

    // ---- sample circular buffer (inferred as BRAM) ----
    // 512 deep so x[n-k] (up to FRAME_LEN + LAG_MAX samples back) never wraps
    // onto the newest samples.
    reg signed [15:0] buf_mem [0:(1<<LOG2_BUF)-1];
    reg [LOG2_BUF-1:0] wr_ptr;

    always @(posedge clk) begin
        if (pcm_valid) begin
            buf_mem[wr_ptr] <= pcm_sample;
            wr_ptr <= wr_ptr + 1'b1;
        end
    end

    // frame boundary: wr_ptr wraps to 0
    reg wr_ptr_prev;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) wr_ptr_prev <= 1'b0;
        else        wr_ptr_prev <= wr_ptr[0];  // unused; frame starts on wrap
    end
    wire frame_start = pcm_valid && (wr_ptr[LOG2_FL-1:0] == {LOG2_FL{1'b0}});

    // ---- FSM ----
    localparam [2:0] S_IDLE  = 3'd0,
                     S_R0    = 3'd1,   // accumulate R[0]
                     S_LAG   = 3'd2,   // accumulate R[lag] for current lag
                     S_PEAK  = 3'd3,   // update peak register
                     S_DONE  = 3'd4;   // latch result

    reg [2:0]               state;
    reg [LOG2_FL-1:0]       smp_idx;    // sample counter within R[k]
    reg [8:0]               cur_lag;    // current lag (LAG_MIN..LAG_MAX)

    // ---- multiply-accumulate (one DSP inferred) ----
    reg signed [15:0] ma_a, ma_b;
    reg signed [35:0] acc;
    wire signed [35:0] acc_next = acc + ma_a * ma_b;

    // R[0] stored for voicing gate
    reg [35:0] r0;

    // peak tracking
    reg [35:0] peak_val;
    reg [8:0]  peak_lag;

    // f0_code computation (used in S_DONE)
    reg [8:0]  d;
    reg [14:0] scaled;
    reg [5:0]  code;
    reg [22:0] q;

    // read address for circular buffer
    wire [LOG2_BUF-1:0] rd_a = wr_ptr - {1'b0, smp_idx} - 1'b1;
    wire [LOG2_BUF-1:0] rd_b = wr_ptr - {1'b0, smp_idx} - cur_lag - 1'b1;

    // registered reads (1-cycle BRAM latency)
    reg signed [15:0] ra_r, rb_r;
    reg [2:0] state_r;
    reg [LOG2_FL-1:0] smp_idx_r;

    always @(posedge clk) begin
        ra_r    <= buf_mem[rd_a];
        rb_r    <= buf_mem[rd_b];
        state_r <= state;
        smp_idx_r <= smp_idx;
    end

    // ---- main FSM ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            smp_idx  <= {LOG2_FL{1'b0}};
            cur_lag  <= LAG_MIN[8:0];
            acc      <= 36'd0;
            r0       <= 36'd0;
            peak_val <= 36'd0;
            peak_lag <= LAG_MIN[8:0];
            f0_valid <= 1'b0;
            f0_code  <= 6'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (frame_start) begin
                        smp_idx  <= {LOG2_FL{1'b0}};
                        acc      <= 36'd0;
                        peak_val <= 36'd0;
                        peak_lag <= LAG_MIN[8:0];
                        cur_lag  <= 9'd0;          // first pass: R[0]
                        state    <= S_R0;
                    end
                end

                // R[0]: autocorrelation at lag 0 (energy, used for voicing gate)
                S_R0: begin
                    if (state_r == S_R0) begin
                        ma_a <= ra_r;
                        ma_b <= ra_r;
                        acc  <= acc_next;
                        smp_idx <= smp_idx_r + 1'b1;
                        if (smp_idx_r == FRAME_LEN - 1) begin
                            r0       <= acc_next;
                            acc      <= 36'd0;
                            smp_idx  <= {LOG2_FL{1'b0}};
                            cur_lag  <= LAG_MIN[8:0];
                            state    <= S_LAG;
                        end
                    end else begin
                        ma_a <= ra_r;
                        ma_b <= ra_r;
                        acc  <= acc_next;
                        smp_idx <= smp_idx + 1'b1;
                    end
                end

                // R[lag]: accumulate over FRAME_LEN samples
                S_LAG: begin
                    ma_a <= ra_r;
                    ma_b <= rb_r;
                    acc  <= acc_next;
                    smp_idx <= smp_idx + 1'b1;
                    if (smp_idx == FRAME_LEN - 1) begin
                        smp_idx <= {LOG2_FL{1'b0}};
                        state   <= S_PEAK;
                    end
                end

                S_PEAK: begin
                    // acc holds R[cur_lag] one cycle delayed; acc_next here is
                    // the last mac; use the registered acc from S_LAG exit.
                    // Still climbing the current peak (previous lag was the best):
                    // any increase wins. A new peak further out (period multiple)
                    // must beat the best by more than 1/8, so the base period wins ties.
                    if (!acc[35] &&
                        ((peak_lag == cur_lag - 9'd1) ? (acc > peak_val)
                         : ({1'b0, acc} > {1'b0, peak_val} + {4'd0, peak_val[35:3]}))) begin
                        peak_val <= acc;
                        peak_lag <= cur_lag;
                    end
                    acc <= 36'd0;
                    if (cur_lag == LAG_MAX[8:0]) begin
                        state <= S_DONE;
                    end else begin
                        cur_lag <= cur_lag + 9'd1;
                        state   <= S_LAG;
                    end
                end

                S_DONE: begin
                    // Voicing gate: unvoiced if energy too low or peak too weak.
                    if (r0[35:10] < VOICED_THR || peak_val < (r0 >> 3)) begin
                        f0_valid <= 1'b0;
                        f0_code  <= 6'd0;
                    end else begin
                        f0_valid <= 1'b1;
                        // Linear map: lag -> code, inverted (low lag = high code).
                        // code = 63 - (peak_lag - LAG_MIN)*63/LAG_RANGE, and
                        // 63/168 = 3/8 exactly, so offset = (d*3) >> 3 (0..63).
                        // Clamped to 1 so a voiced frame never reads as code 0.
                        begin
                            d = peak_lag - LAG_MIN[8:0];
                            scaled = d * 4'd3;
                            code = scaled[8:3];
                            f0_code <= (code == 6'd63) ? 6'd1 : 6'd63 - code;
                        end
                    end
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
