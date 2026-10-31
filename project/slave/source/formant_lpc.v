`timescale 1ns/1ps
// Vowel formant (F1/F2) estimator: 18th-order LPC envelope minima.
//
// Every 256 new samples (16 ms @ 16 kHz, same cadence as f0_autocorr) one frame
// of the most recent 400 samples (plus the one before, for pre-emphasis) is
// processed, fully serially:
//   1. COPY : y[n] = x[n] - (x[n-1]*31785 >>> 15)  (17 bit, as speech_mfcc_frame)
//             yw[n] = (y[n]*w[n]) >>> 15, w = Hamming Q15 (window.hex), 17 bit
//   2. AC   : r[k] = sum_{n=0}^{399-k} yw[n]*yw[n+k], k = 0..18, exact (44 bit)
//   3. GATE : r[0] < ENERGY_THR -> frame invalid
//   4. NORM : r'[k] = r[k] shifted so that r'[0] is in [2^30, 2^31) (Q31, 32 bit)
//   5. LEVINSON (order 18):
//        a_j Q27 (32 bit signed, |a| < 16), k Q30, err Q31,
//        acc = r'[i]<<27 + sum a_j r'[i-j]   (exact, 70 bit)
//        k   = -acc / (err<<27)             (30-step restoring division)
//        a_j += (k*a_{i-j}) >>> 30, a_i = k >>> 3
//        err -= (err * ((k*k)>>>30)) >>> 30
//      invalid if err <= 0, |acc| >= err<<27 (|k| >= 1) or any a_j overflows.
//   6. ENV  : for kk = 0..127: re = sum a_i cos(2*pi*i*kk/512),
//             im = sum a_i sin(...)  (cos.hex Q15, sin = cos index - 128, exact),
//             P = (re>>>20)^2 + (im>>>20)^2  (Q44, 64 bit)
//   7. PEAK : local minima P[c] < P[c-1] && P[c] <= P[c+1], c = 7..126;
//             first -> f1_bin, second -> f2_bin; fewer than two, or f1 > 63
//             (not representable in 6 bits) -> invalid.
// Multipliers: one 18x18 DSP (COPY, AC, ENV; ENV splits a into a signed high
// 18-bit and an unsigned low 14-bit part) and one 32x32 shift-add serial
// multiplier in LUTs (LEVINSON, squares in ENV).
// Compute time ~56k clk per frame; budget at 16 kHz / 50 MHz is 800k clk.
// The 512-deep sample buffer is overwritten from the oldest end while a frame
// is being copied, so COPY (~2.8k clk) must finish before 111 new samples arrive.
// A frame trigger that arrives while busy is dropped (overrun pulse).
// Outputs are updated once per frame and held until the next one.
// Spectrogram column (spec_valid / spec_col), from the same P[kk] as PEAK:
//   msb[kk] = position of the highest set bit of P[kk] (0 if P[kk] <= 1),
//   mag[kk] = clamp(SPEC_REF - msb[kk], 0, 15)  (4 bit, ~3 dB per step;
//             P = |A|^2, so mag follows the envelope 1/|A|^2: formants are high),
//   point i = max(mag[2i], mag[2i+1]), i = 0..63 (62.5 Hz per point),
//   spec_col[4i+3:4i] = point i.
// spec_valid pulses once per frame (every S_OUT, also failed frames) together
// with frame_done; spec_col is updated in the same clk and held. Frames that
// end with F_OK / F_NOMIN / F_F1RANGE (all 128 P computed) carry their 64
// points; all other failed frames give spec_col = 0.
// P[kk] is registered at the last S_SQ phase and reduced to mag in the next
// clk; for kk = 127 that clk is S_FIN, so the column is complete in S_OUT.
module formant_lpc #(
    parameter integer ENERGY_THR  = 32768,   // threshold on raw r[0]
    parameter integer SPEC_REF    = 48,      // spectrogram: mag = SPEC_REF - msb(P)
    parameter         WINDOW_FILE = "speech_assets/window.hex",
    parameter         COS_FILE    = "speech_assets/cos.hex"
) (
    input  wire               clk, rst_n,
    input  wire               pcm_valid,      // single-cycle pulse ~16 kHz
    input  wire signed [15:0] pcm_sample,
    output reg                vowel_valid,    // updated each frame, held until next
    output reg  [5:0]         f1_bin,         // F1 / 31.25 Hz
    output reg  [6:0]         f2_bin,         // F2 / 31.25 Hz
    output reg                spec_valid,     // 1-clk pulse each frame (S_OUT)
    output reg  [255:0]       spec_col        // 64 x 4-bit points, held until next frame
);
    localparam [43:0] THR44 = ENERGY_THR;
    localparam [7:0]  SPEC_REF8 = SPEC_REF;

    // failure codes (debug / testbench only)
    localparam [2:0] F_OK = 3'd0, F_UNPRIMED = 3'd1, F_THR = 3'd2, F_ERR = 3'd3,
                     F_K = 3'd4, F_OVF = 3'd5, F_NOMIN = 3'd6, F_F1RANGE = 3'd7;

    localparam [4:0] S_IDLE   = 5'd0,  S_PRE    = 5'd1,  S_CP     = 5'd2,
                     S_AC     = 5'd3,  S_GATE   = 5'd4,  S_NRM    = 5'd5,
                     S_LV_I   = 5'd6,  S_LV_ACC = 5'd7,  S_LV_CHK = 5'd8,
                     S_LV_DIV = 5'd9,  S_LV_UPD = 5'd10, S_LV_AI  = 5'd11,
                     S_LV_ERR = 5'd12, S_ENV    = 5'd13, S_SQ     = 5'd14,
                     S_FIN    = 5'd15, S_OUT    = 5'd16;

    // ---------------- sample ring buffer (BRAM) ----------------
    reg signed [15:0] buf_mem [0:511];
    reg [8:0]         wr_ptr;
    reg               primed;          // >= 401 samples received since reset
    reg [8:0]         buf_raddr;
    reg signed [15:0] buf_q;

    always @(posedge clk) begin
        if (pcm_valid) buf_mem[wr_ptr] <= pcm_sample;
        buf_q <= buf_mem[buf_raddr];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= 9'd0;
            primed <= 1'b0;
        end else if (pcm_valid) begin
            wr_ptr <= wr_ptr + 9'd1;
            if (wr_ptr == 9'd400) primed <= 1'b1;
        end
    end

    // frame trigger: the sample just written lands at address 255 or 511
    wire trig = pcm_valid && (wr_ptr[7:0] == 8'hff);

    // ---------------- ROMs ----------------
    reg [15:0] win_rom [0:399];
    reg [15:0] cos_rom [0:511];
    initial begin
        $readmemh(WINDOW_FILE, win_rom);
        $readmemh(COS_FILE, cos_rom);
    end
    reg [8:0]  win_addr, cos_addr;
    reg [15:0] win_q, cos_q;
    always @(posedge clk) begin
        win_q <= win_rom[win_addr];
        cos_q <= cos_rom[cos_addr];
    end

    // ---------------- windowed frame yw[0..399] (BRAM, 2 read ports) ----------------
    reg signed [16:0] yw_mem [0:511];
    reg               yw_we;
    reg [8:0]         yw_waddr, ya_addr, yb_addr;
    reg [16:0]        yw_wdata;
    reg signed [16:0] ya_q, yb_q;
    always @(posedge clk) begin
        if (yw_we) yw_mem[yw_waddr] <= yw_wdata;
        ya_q <= yw_mem[ya_addr];
        yb_q <= yw_mem[yb_addr];
    end

    // ---------------- r[0..18] (raw, then normalized in place) ----------------
    reg [43:0] rmem [0:31];
    reg        r_we;
    reg [4:0]  r_waddr, r_raddr;
    reg [43:0] r_wdata, r_q;
    always @(posedge clk) begin
        if (r_we) rmem[r_waddr] <= r_wdata;
        r_q <= rmem[r_raddr];
    end

    // ---------------- LPC coefficients, ping-pong banks {bank, j} ----------------
    reg [31:0] amem [0:63];
    reg        a_we;
    reg [5:0]  a_waddr, a_raddr;
    reg [31:0] a_wdata, a_q;
    always @(posedge clk) begin
        if (a_we) amem[a_waddr] <= a_wdata;
        a_q <= amem[a_raddr];
    end

    // ---------------- shared 18x18 multiplier (one DSP) ----------------
    reg signed [17:0] m_a, m_b;
    reg signed [35:0] m_p;
    always @(posedge clk) m_p <= m_a * m_b;

    // ---------------- 32x32 signed serial multiplier (32 clk) ----------------
    reg               mul_start;
    reg        [31:0] mul_x, mul_y;
    reg        [31:0] mx;
    reg        [63:0] mp;
    reg        [4:0]  mcnt;
    reg               mbusy, mul_done, mneg;
    wire       [32:0] msum = {1'b0, mp[63:32]} + (mp[0] ? {1'b0, mx} : 33'd0);
    wire signed [63:0] mres    = mneg ? -$signed(mp) : $signed(mp);
    wire signed [63:0] mres_sh = mres >>> 30;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mx <= 32'd0; mp <= 64'd0; mcnt <= 5'd0;
            mbusy <= 1'b0; mul_done <= 1'b0; mneg <= 1'b0;
        end else begin
            mul_done <= 1'b0;
            if (mul_start) begin
                mx    <= mul_x[31] ? (~mul_x + 32'd1) : mul_x;
                mp    <= {32'd0, (mul_y[31] ? (~mul_y + 32'd1) : mul_y)};
                mneg  <= mul_x[31] ^ mul_y[31];
                mcnt  <= 5'd0;
                mbusy <= 1'b1;
            end else if (mbusy) begin
                mp   <= {msum, mp[31:1]};
                mcnt <= mcnt + 5'd1;
                if (mcnt == 5'd31) begin
                    mbusy    <= 1'b0;
                    mul_done <= 1'b1;
                end
            end
        end
    end

    // ---------------- main FSM ----------------
    reg [4:0]  state;
    reg [3:0]  ph;
    reg [2:0]  fail_code;               // last frame's result (debug)
    reg        frame_done;              // 1-clk pulse when outputs are updated
    reg        overrun;                 // 1-clk pulse: trigger while busy (dropped)
    wire       busy = (state != S_IDLE);

    reg [8:0]  base;                    // address of x[-1]
    reg [8:0]  n;                       // COPY sample index
    reg signed [15:0] x_prev, x_cur;
    reg [15:0] w_r;

    reg [4:0]  lag;
    reg [8:0]  iss_n;
    reg        iss_on, v0, v1, v2, v3;
    reg [69:0] acc;                     // AC sum / Levinson acc
    reg [43:0] r0;

    reg [5:0]  scnt;
    reg        sdir;                    // 1 = right shift
    reg [43:0] sreg;

    reg [4:0]  li, lj;
    reg [31:0] err, kref, k2;
    reg [59:0] div_rem;
    reg [29:0] div_q;
    reg [4:0]  div_cnt;

    reg [6:0]  kk;
    reg [4:0]  ti;
    reg [8:0]  ci;
    reg [31:0] a_r;
    reg [15:0] c_r, s_r;
    reg [55:0] re_acc, im_acc;
    reg [63:0] psum, p_m1, p_m2;
    reg [1:0]  nf;
    reg [6:0]  f1c, f2c;

    // COPY datapath
    wire signed [35:0] m_p_sh15 = m_p >>> 15;          // standalone: arithmetic shift
    wire signed [35:0] pre_full = {{20{x_cur[15]}}, x_cur} - m_p_sh15;

    // NORM: msb position of r0 (r0 > 0 here)
    reg [5:0] r0_msb;
    integer   bi;
    always @(*) begin
        r0_msb = 6'd0;
        for (bi = 0; bi < 43; bi = bi + 1)
            if (r0[bi]) r0_msb = bi[5:0];
    end

    // Levinson helpers
    wire [69:0] acc_abs = acc[69] ? (~acc + 70'd1) : acc;
    wire [69:0] d70     = {11'd0, err, 27'd0};
    wire [59:0] d60     = {1'b0, err, 27'd0};
    wire [59:0] rem2    = {div_rem[58:0], 1'b0};
    wire [33:0] usum    = {{2{a_q[31]}}, a_q} + mres_sh[33:0];
    wire        usum_ovf = (usum[33:31] != 3'b000) && (usum[33:31] != 3'b111);
    wire [31:0] kq      = {2'b00, div_q};
    wire [31:0] k_new   = (!acc[69] && acc != 70'd0) ? (~kq + 32'd1) : kq;

    // ENV helpers
    wire [31:0] re32 = re_acc[51:20];
    wire [31:0] im32 = im_acc[51:20];
    wire [64:0] pcur = {1'b0, psum} + {1'b0, mres};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; ph <= 4'd0;
            vowel_valid <= 1'b0; f1_bin <= 6'd0; f2_bin <= 7'd0;
            fail_code <= F_UNPRIMED; frame_done <= 1'b0; overrun <= 1'b0;
            base <= 9'd0; n <= 9'd0; x_prev <= 16'sd0; x_cur <= 16'sd0; w_r <= 16'd0;
            buf_raddr <= 9'd0; win_addr <= 9'd0; cos_addr <= 9'd0;
            yw_we <= 1'b0; yw_waddr <= 9'd0; yw_wdata <= 17'd0; ya_addr <= 9'd0; yb_addr <= 9'd0;
            r_we <= 1'b0; r_waddr <= 5'd0; r_raddr <= 5'd0; r_wdata <= 44'd0;
            a_we <= 1'b0; a_waddr <= 6'd0; a_raddr <= 6'd0; a_wdata <= 32'd0;
            m_a <= 18'sd0; m_b <= 18'sd0;
            mul_start <= 1'b0; mul_x <= 32'd0; mul_y <= 32'd0;
            lag <= 5'd0; iss_n <= 9'd0; iss_on <= 1'b0;
            v0 <= 1'b0; v1 <= 1'b0; v2 <= 1'b0; v3 <= 1'b0;
            acc <= 70'd0; r0 <= 44'd0;
            scnt <= 6'd0; sdir <= 1'b0; sreg <= 44'd0;
            li <= 5'd0; lj <= 5'd0; err <= 32'd0; kref <= 32'd0; k2 <= 32'd0;
            div_rem <= 60'd0; div_q <= 30'd0; div_cnt <= 5'd0;
            kk <= 7'd0; ti <= 5'd0; ci <= 9'd0; a_r <= 32'd0; c_r <= 16'd0; s_r <= 16'd0;
            re_acc <= 56'd0; im_acc <= 56'd0; psum <= 64'd0; p_m1 <= 64'd0; p_m2 <= 64'd0;
            nf <= 2'd0; f1c <= 7'd0; f2c <= 7'd0;
        end else begin
            yw_we      <= 1'b0;
            r_we       <= 1'b0;
            a_we       <= 1'b0;
            mul_start  <= 1'b0;
            frame_done <= 1'b0;
            overrun    <= trig && busy;
            v1 <= v0; v2 <= v1; v3 <= v2;

            case (state)
            S_IDLE: begin
                if (trig) begin
                    base      <= wr_ptr + 9'd112;      // newest - 400
                    buf_raddr <= wr_ptr + 9'd112;
                    ph        <= 4'd0;
                    if (!primed) begin
                        fail_code <= F_UNPRIMED;
                        state     <= S_OUT;
                    end else begin
                        state <= S_PRE;
                    end
                end
            end

            // x[-1]
            S_PRE: begin
                if (ph == 4'd0) ph <= 4'd1;
                else begin
                    x_prev <= buf_q;
                    n      <= 9'd0;
                    ph     <= 4'd0;
                    state  <= S_CP;
                end
            end

            // pre-emphasis + window, one sample per 7 clk
            S_CP: begin
                case (ph)
                4'd0: begin buf_raddr <= base + 9'd1 + n; win_addr <= n; ph <= 4'd1; end
                4'd1: ph <= 4'd2;
                4'd2: begin
                    x_cur <= buf_q;
                    w_r   <= win_q;
                    m_a   <= {{2{x_prev[15]}}, x_prev};
                    m_b   <= 18'sd31785;
                    ph    <= 4'd3;
                end
                4'd3: ph <= 4'd4;
                4'd4: begin
                    m_a <= {pre_full[16], pre_full[16:0]};
                    m_b <= {2'b00, w_r};
                    ph  <= 4'd5;
                end
                4'd5: ph <= 4'd6;
                default: begin
                    yw_we    <= 1'b1;
                    yw_waddr <= n;
                    yw_wdata <= m_p_sh15[16:0];
                    x_prev   <= x_cur;
                    ph       <= 4'd0;
                    if (n == 9'd399) begin
                        lag    <= 5'd0;
                        iss_n  <= 9'd0;
                        iss_on <= 1'b1;
                        acc    <= 70'd0;
                        state  <= S_AC;
                    end else begin
                        n <= n + 9'd1;
                    end
                end
                endcase
            end

            // autocorrelation, pipelined: issue -> read -> DSP in -> DSP out -> acc
            S_AC: begin
                if (iss_on) begin
                    ya_addr <= iss_n;
                    yb_addr <= iss_n + {4'd0, lag};
                    v0      <= 1'b1;
                    iss_n   <= iss_n + 9'd1;
                    if (iss_n == 9'd399 - {4'd0, lag}) iss_on <= 1'b0;
                end else begin
                    v0 <= 1'b0;
                end
                if (v1) begin
                    m_a <= {ya_q[16], ya_q};
                    m_b <= {yb_q[16], yb_q};
                end
                if (v3) acc <= acc + {{34{m_p[35]}}, m_p};
                if (!iss_on && !v0 && !v1 && !v2 && !v3) begin
                    r_we    <= 1'b1;
                    r_waddr <= lag;
                    r_wdata <= acc[43:0];
                    if (lag == 5'd0) r0 <= acc[43:0];
                    if (lag == 5'd18) begin
                        state <= S_GATE;
                    end else begin
                        lag    <= lag + 5'd1;
                        iss_n  <= 9'd0;
                        iss_on <= 1'b1;
                        acc    <= 70'd0;
                    end
                end
            end

            S_GATE: begin
                if (r0[43] || r0 == 44'd0 || r0 < THR44) begin
                    fail_code <= F_THR;
                    state     <= S_OUT;
                end else begin
                    lag   <= 5'd0;
                    ph    <= 4'd0;
                    state <= S_NRM;
                end
            end

            // r'[k] = r[k] << (30-msb) or >>> (msb-30), one bit per clk
            S_NRM: begin
                case (ph)
                4'd0: begin r_raddr <= lag; ph <= 4'd1; end
                4'd1: ph <= 4'd2;
                4'd2: begin
                    sreg <= r_q;
                    if (r0_msb > 6'd30) begin sdir <= 1'b1; scnt <= r0_msb - 6'd30; end
                    else                begin sdir <= 1'b0; scnt <= 6'd30 - r0_msb; end
                    ph <= 4'd3;
                end
                default: begin
                    if (scnt != 6'd0) begin
                        sreg <= sdir ? {sreg[43], sreg[43:1]} : {sreg[42:0], 1'b0};
                        scnt <= scnt - 6'd1;
                    end else begin
                        r_we    <= 1'b1;
                        r_waddr <= lag;
                        r_wdata <= sreg;
                        if (lag == 5'd0) err <= sreg[31:0];
                        ph <= 4'd0;
                        if (lag == 5'd18) begin
                            li    <= 5'd1;
                            state <= S_LV_I;
                        end else begin
                            lag <= lag + 5'd1;
                        end
                    end
                end
                endcase
            end

            // ---- Levinson-Durbin, iteration li = 1..18 ----
            S_LV_I: begin
                case (ph)
                4'd0: begin r_raddr <= li; ph <= 4'd1; end
                4'd1: ph <= 4'd2;
                default: begin
                    acc <= {{11{r_q[31]}}, r_q[31:0], 27'd0};
                    lj  <= 5'd1;
                    ph  <= 4'd0;
                    state <= (li == 5'd1) ? S_LV_CHK : S_LV_ACC;
                end
                endcase
            end

            // acc += a_old[lj] * r'[li-lj]
            S_LV_ACC: begin
                case (ph)
                4'd0: begin
                    a_raddr <= {~li[0], lj};
                    r_raddr <= li - lj;
                    ph      <= 4'd1;
                end
                4'd1: ph <= 4'd2;
                4'd2: begin
                    mul_x     <= a_q;
                    mul_y     <= r_q[31:0];
                    mul_start <= 1'b1;
                    ph        <= 4'd3;
                end
                default: begin
                    if (mul_done) begin
                        acc <= acc + {{6{mres[63]}}, mres};
                        ph  <= 4'd0;
                        if (lj == li - 5'd1) state <= S_LV_CHK;
                        else                 lj <= lj + 5'd1;
                    end
                end
                endcase
            end

            S_LV_CHK: begin
                if (err[31] || err == 32'd0) begin
                    fail_code <= F_ERR;
                    state     <= S_OUT;
                end else if (acc_abs >= d70) begin
                    fail_code <= F_K;
                    state     <= S_OUT;
                end else begin
                    div_rem <= acc_abs[59:0];
                    div_q   <= 30'd0;
                    div_cnt <= 5'd0;
                    state   <= S_LV_DIV;
                end
            end

            // q = floor(|acc| * 2^30 / (err<<27)), 30 restoring steps
            S_LV_DIV: begin
                if (div_cnt == 5'd30) begin
                    kref  <= k_new;
                    lj    <= 5'd1;
                    ph    <= 4'd0;
                    state <= (li == 5'd1) ? S_LV_AI : S_LV_UPD;
                end else begin
                    if (rem2 >= d60) begin
                        div_rem <= rem2 - d60;
                        div_q   <= {div_q[28:0], 1'b1};
                    end else begin
                        div_rem <= rem2;
                        div_q   <= {div_q[28:0], 1'b0};
                    end
                    div_cnt <= div_cnt + 5'd1;
                end
            end

            // a_new[lj] = a_old[lj] + (k * a_old[li-lj]) >>> 30
            S_LV_UPD: begin
                case (ph)
                4'd0: begin a_raddr <= {~li[0], li - lj}; ph <= 4'd1; end
                4'd1: ph <= 4'd2;
                4'd2: begin
                    mul_x     <= kref;
                    mul_y     <= a_q;
                    mul_start <= 1'b1;
                    a_raddr   <= {~li[0], lj};
                    ph        <= 4'd3;
                end
                default: begin
                    if (mul_done) begin
                        if (usum_ovf) begin
                            fail_code <= F_OVF;
                            state     <= S_OUT;
                        end else begin
                            a_we    <= 1'b1;
                            a_waddr <= {li[0], lj};
                            a_wdata <= usum[31:0];
                            ph      <= 4'd0;
                            if (lj == li - 5'd1) state <= S_LV_AI;
                            else                 lj <= lj + 5'd1;
                        end
                    end
                end
                endcase
            end

            // a_new[li] = k >>> 3 (Q30 -> Q27)
            S_LV_AI: begin
                a_we    <= 1'b1;
                a_waddr <= {li[0], li};
                a_wdata <= {{3{kref[31]}}, kref[31:3]};
                ph      <= 4'd0;
                state   <= S_LV_ERR;
            end

            // err -= (err * ((k*k)>>>30)) >>> 30
            S_LV_ERR: begin
                case (ph)
                4'd0: begin mul_x <= kref; mul_y <= kref; mul_start <= 1'b1; ph <= 4'd1; end
                4'd1: if (mul_done) begin k2 <= mres_sh[31:0]; ph <= 4'd2; end
                4'd2: begin mul_x <= err; mul_y <= k2; mul_start <= 1'b1; ph <= 4'd3; end
                default: begin
                    if (mul_done) begin
                        err <= err - mres_sh[31:0];
                        ph  <= 4'd0;
                        if (li == 5'd18) begin
                            kk     <= 7'd0;
                            ti     <= 5'd0;
                            ci     <= 9'd0;
                            re_acc <= 56'd0;
                            im_acc <= 56'd0;
                            nf     <= 2'd0;
                            state  <= S_ENV;
                        end else begin
                            li    <= li + 5'd1;
                            state <= S_LV_I;
                        end
                    end
                end
                endcase
            end

            // ---- envelope: re/im of A(e^{jw}) at w = 2*pi*kk/512, a in bank 0 ----
            S_ENV: begin
                case (ph)
                4'd0: begin a_raddr <= {1'b0, ti}; cos_addr <= ci; ph <= 4'd1; end
                4'd1: ph <= 4'd2;
                4'd2: begin
                    a_r      <= (ti == 5'd0) ? 32'h0800_0000 : a_q;   // a_0 = 1.0 Q27
                    c_r      <= cos_q;
                    cos_addr <= ci - 9'd128;                          // sin
                    ph       <= 4'd3;
                end
                4'd3: begin m_a <= a_r[31:14]; m_b <= {{2{c_r[15]}}, c_r}; ph <= 4'd4; end
                4'd4: begin
                    m_a <= {4'd0, a_r[13:0]}; m_b <= {{2{c_r[15]}}, c_r};
                    s_r <= cos_q;
                    ph  <= 4'd5;
                end
                4'd5: begin
                    re_acc <= re_acc + {{6{m_p[35]}}, m_p, 14'd0};
                    m_a <= a_r[31:14]; m_b <= {{2{s_r[15]}}, s_r};
                    ph  <= 4'd6;
                end
                4'd6: begin
                    re_acc <= re_acc + {{20{m_p[35]}}, m_p};
                    m_a <= {4'd0, a_r[13:0]}; m_b <= {{2{s_r[15]}}, s_r};
                    ph  <= 4'd7;
                end
                4'd7: begin
                    im_acc <= im_acc + {{6{m_p[35]}}, m_p, 14'd0};
                    ph     <= 4'd8;
                end
                default: begin
                    im_acc <= im_acc + {{20{m_p[35]}}, m_p};
                    ph     <= 4'd0;
                    if (ti == 5'd18) begin
                        state <= S_SQ;
                    end else begin
                        ti <= ti + 5'd1;
                        ci <= ci + {2'd0, kk};
                    end
                end
                endcase
            end

            // P[kk] = re32^2 + im32^2, then local-minimum test on P[kk-1]
            S_SQ: begin
                case (ph)
                4'd0: begin mul_x <= re32; mul_y <= re32; mul_start <= 1'b1; ph <= 4'd1; end
                4'd1: if (mul_done) begin psum <= mres; ph <= 4'd2; end
                4'd2: begin mul_x <= im32; mul_y <= im32; mul_start <= 1'b1; ph <= 4'd3; end
                default: begin
                    if (mul_done) begin
                        if (kk >= 7'd8 && p_m1 < p_m2 && {1'b0, p_m1} <= pcur) begin
                            if (nf == 2'd0) begin f1c <= kk - 7'd1; nf <= 2'd1; end
                            else if (nf == 2'd1) begin f2c <= kk - 7'd1; nf <= 2'd2; end
                        end
                        p_m2 <= p_m1;
                        p_m1 <= pcur[63:0];
                        ph   <= 4'd0;
                        if (kk == 7'd127) begin
                            state <= S_FIN;
                        end else begin
                            kk     <= kk + 7'd1;
                            ti     <= 5'd0;
                            ci     <= 9'd0;
                            re_acc <= 56'd0;
                            im_acc <= 56'd0;
                            state  <= S_ENV;
                        end
                    end
                end
                endcase
            end

            S_FIN: begin
                if (nf != 2'd2)          fail_code <= F_NOMIN;
                else if (f1c > 7'd63)    fail_code <= F_F1RANGE;
                else                     fail_code <= F_OK;
                state <= S_OUT;
            end

            // fail_code is final here (set by the state that jumped to S_OUT)
            default: begin   // S_OUT
                if (fail_code == F_OK) begin
                    vowel_valid <= 1'b1;
                    f1_bin      <= f1c[5:0];
                    f2_bin      <= f2c;
                end else begin
                    vowel_valid <= 1'b0;
                    f1_bin      <= 6'd0;
                    f2_bin      <= 7'd0;
                end
                frame_done <= 1'b1;
                state      <= S_IDLE;
            end
            endcase
        end
    end

    // ---------------- spectrogram column ----------------
    // sp_p <= P[kk] at the last S_SQ phase (same clk as the PEAK update);
    // next clk: mag from sp_p, even kk kept in sp_even, odd kk shifts
    // max(sp_even, mag) into spec_acc from the top (point 0 ends at [3:0]).
    reg         sp_v;                   // sp_p holds a new P
    reg         sp_odd;                 // ... of an odd kk
    reg  [64:0] sp_p;
    reg  [3:0]  sp_even;
    reg  [255:0] spec_acc;

    // msb position of sp_p (0 for sp_p <= 1)
    reg  [6:0]  sp_msb;
    integer     si;
    always @(*) begin
        sp_msb = 7'd0;
        for (si = 0; si < 65; si = si + 1)
            if (sp_p[si]) sp_msb = si[6:0];
    end
    wire [7:0]  sp_d   = SPEC_REF8 - {1'b0, sp_msb};
    wire [3:0]  sp_mag = ({1'b0, sp_msb} >= SPEC_REF8) ? 4'd0 :
                         (sp_d > 8'd15)                ? 4'd15 : sp_d[3:0];
    wire [3:0]  sp_pt  = (sp_mag > sp_even) ? sp_mag : sp_even;
    wire        sp_ok  = (fail_code == F_OK) || (fail_code == F_NOMIN) ||
                         (fail_code == F_F1RANGE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sp_v <= 1'b0; sp_odd <= 1'b0; sp_p <= 65'd0; sp_even <= 4'd0;
            spec_acc <= 256'd0; spec_valid <= 1'b0; spec_col <= 256'd0;
        end else begin
            sp_v <= 1'b0;
            if (state == S_SQ && ph >= 4'd3 && mul_done) begin
                sp_v   <= 1'b1;
                sp_odd <= kk[0];
                sp_p   <= pcur;
            end
            if (sp_v) begin
                if (!sp_odd) sp_even  <= sp_mag;
                else         spec_acc <= {sp_pt, spec_acc[255:4]};
            end
            // S_OUT: fail_code is final; the kk = 127 point was shifted in on S_FIN
            spec_valid <= (state == S_OUT);
            if (state == S_OUT) spec_col <= sp_ok ? spec_acc : 256'd0;
        end
    end
endmodule
