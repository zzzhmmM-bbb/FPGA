`timescale 1ns/1ps
// T10 f0_autocorr silent-frame gate: lock-step comparison against the T9
// original (renamed f0_autocorr_ref, copied outside the package).
// Compile: iverilog -g2012 -o sim tb_f0_gate.v <ref f0_autocorr_ref.v> <new f0_autocorr.v>
// Pass criteria are judged by the caller from the printed raw counts.
module tb_f0_gate;
    reg clk = 1'b0;
    always #10 clk = ~clk;              // 50 MHz, same as board2
    reg rst_n = 1'b0;
    reg pcm_valid = 1'b0;
    reg signed [15:0] pcm_sample = 16'sd0;

    wire        v_ref, v_new;
    wire [5:0]  c_ref, c_new;

    f0_autocorr_ref #(.FRAME_LEN(256), .LAG_MIN(32), .LAG_MAX(200), .VOICED_THR(512)) u_ref (
        .clk(clk), .rst_n(rst_n), .pcm_valid(pcm_valid), .pcm_sample(pcm_sample),
        .f0_valid(v_ref), .f0_code(c_ref));
    f0_autocorr     #(.FRAME_LEN(256), .LAG_MIN(32), .LAG_MAX(200), .VOICED_THR(512)) u_new (
        .clk(clk), .rst_n(rst_n), .pcm_valid(pcm_valid), .pcm_sample(pcm_sample),
        .f0_valid(v_new), .f0_code(c_new));

    // FPGA configuration leaves un-reset registers / BRAM at 0; mirror that.
    integer i;
    initial begin
        u_ref.wr_ptr = 0; u_new.wr_ptr = 0;
        u_ref.ma_a = 0; u_ref.ma_b = 0; u_new.ma_a = 0; u_new.ma_b = 0;
        u_ref.ra_r = 0; u_ref.rb_r = 0; u_new.ra_r = 0; u_new.rb_r = 0;
        u_ref.state_r = 0; u_new.state_r = 0; u_ref.smp_idx_r = 0; u_new.smp_idx_r = 0;
        for (i = 0; i < 512; i = i + 1) begin u_ref.buf_mem[i] = 0; u_new.buf_mem[i] = 0; end
    end

    // ---------------- comparison and activity counters ----------------
    integer cycles = 0, mismatch = 0, first_mm = -1;
    integer frames_ref = 0, frames_new = 0, voiced_frames = 0, silent_frames = 0;
    integer gated_cycles = 0;                       // ref in S_LAG/S_PEAK with silent r0
    integer tog_ma_ref_s = 0, tog_ma_new_s = 0;     // operand bit toggles, silent lag phase
    integer tog_rd_ref_s = 0, tog_rd_new_s = 0;     // BRAM read-register bit toggles, silent lag phase
    integer tog_acc_ref_s = 0, tog_acc_new_s = 0;
    integer tog_ma_ref_all = 0, tog_ma_new_all = 0; // whole run
    integer state_mm = 0;
    integer near_thr = 0, near_thr_silent = 0;      // frames with r0[35:10] in [448,576]
    reg [15:0] pa_r, pb_r, pa_n, pb_n, qa_r, qb_r, qa_n, qb_n;
    reg [35:0] pacc_r, pacc_n;
    integer seg_frames [0:15];
    integer seg_voiced [0:15];
    integer seg_id = 0;

    function integer popc32;
        input [35:0] x;
        begin popc32 = $countones(x); end
    endfunction

    wire ref_silent_lag = (u_ref.state == 3'd2 || u_ref.state == 3'd3) && (u_ref.r0[35:10] < 512);

    always @(posedge clk) begin
        if (rst_n) begin
            cycles = cycles + 1;
            if (v_ref !== v_new || c_ref !== c_new) begin
                mismatch = mismatch + 1;
                if (first_mm < 0) first_mm = cycles;
            end
            if (u_ref.state !== u_new.state) state_mm = state_mm + 1;
            if (u_ref.state == 3'd4) begin
                frames_ref = frames_ref + 1;
                seg_frames[seg_id] = seg_frames[seg_id] + 1;
                if (u_ref.r0[35:10] < 512) silent_frames = silent_frames + 1;
                if (u_ref.r0[35:10] >= 448 && u_ref.r0[35:10] <= 576) begin
                    near_thr = near_thr + 1;
                    if (u_ref.r0[35:10] < 512) near_thr_silent = near_thr_silent + 1;
                end
            end
            if (u_new.state == 3'd4) frames_new = frames_new + 1;
            tog_ma_ref_all = tog_ma_ref_all + popc32(u_ref.ma_a ^ pa_r) + popc32(u_ref.ma_b ^ pb_r);
            tog_ma_new_all = tog_ma_new_all + popc32(u_new.ma_a ^ pa_n) + popc32(u_new.ma_b ^ pb_n);
            if (ref_silent_lag) begin
                gated_cycles = gated_cycles + 1;
                tog_ma_ref_s = tog_ma_ref_s + popc32(u_ref.ma_a ^ pa_r) + popc32(u_ref.ma_b ^ pb_r);
                tog_ma_new_s = tog_ma_new_s + popc32(u_new.ma_a ^ pa_n) + popc32(u_new.ma_b ^ pb_n);
                tog_rd_ref_s = tog_rd_ref_s + popc32(u_ref.ra_r ^ qa_r) + popc32(u_ref.rb_r ^ qb_r);
                tog_rd_new_s = tog_rd_new_s + popc32(u_new.ra_r ^ qa_n) + popc32(u_new.rb_r ^ qb_n);
                tog_acc_ref_s = tog_acc_ref_s + popc32(u_ref.acc ^ pacc_r);
                tog_acc_new_s = tog_acc_new_s + popc32(u_new.acc ^ pacc_n);
            end
        end
        pa_r = u_ref.ma_a; pb_r = u_ref.ma_b; pa_n = u_new.ma_a; pb_n = u_new.ma_b;
        qa_r = u_ref.ra_r; qb_r = u_ref.rb_r; qa_n = u_new.ra_r; qb_n = u_new.rb_r;
        pacc_r = u_ref.acc; pacc_n = u_new.acc;
    end
    always @(posedge clk) if (rst_n && u_ref.state == 3'd4 &&
        !(u_ref.r0[35:10] < 512 || u_ref.peak_val < (u_ref.r0 >> 3))) begin
        voiced_frames = voiced_frames + 1;
        seg_voiced[seg_id] = seg_voiced[seg_id] + 1;
    end

    // ---------------- stimulus ----------------
    real PI = 3.14159265358979;
    real ph, ph2, env, f, a, x;
    integer seed = 32'h5EED_F00D;
    integer n, gap, kind;

    task push(input integer val, input integer spacing);
        integer s, v;
        begin
            v = val;
            if (v > 32767) v = 32767;
            if (v < -32768) v = -32768;
            repeat (spacing - 1) @(posedge clk);
            pcm_sample <= v[15:0];
            pcm_valid  <= 1'b1;
            @(posedge clk);
            pcm_valid  <= 1'b0;
        end
    endtask

    function integer spacing_fn(input integer mode);
        begin
            // mode 0: jittered 180..259 cycles (FSM ~43.7k cycles < 256 samples)
            // mode 1: 3125 cycles (real 16 kHz)  mode 2: 100 cycles (frame overrun)
            if (mode == 1) spacing_fn = 3125;
            else if (mode == 2) spacing_fn = 100;
            else spacing_fn = 180 + ({$random(seed)} % 80);
        end
    endfunction

    // one segment = nfr frames of one stimulus kind
    task segment(input integer k, input integer nfr, input integer smode, input real p1);
        integer m;
        begin
            seg_id = k;
            $display("PROGRESS t=%0t cycles=%0d frames_ref=%0d mismatch=%0d start kind %0d x%0d", $time, cycles, frames_ref, mismatch, k, nfr);
            for (m = 0; m < nfr * 256; m = m + 1) begin
                case (k)
                    0: x = 0.0;                                           // silence
                    1: x = $itor(($random(seed) % 9));                    // low noise +-8
                    2: x = $itor(($random(seed) % 9)) * p1;               // near-threshold noise
                    3: begin x = p1 * $sin(ph); ph = ph + 2.0*PI*100.0/16000.0; end
                    4: begin x = p1 * $sin(ph); ph = ph + 2.0*PI*200.0/16000.0; end
                    5: begin x = p1 * $sin(ph); ph = ph + 2.0*PI*400.0/16000.0; end
                    6: begin                                              // speech-like
                        if ((m % 64) == 0) begin
                            f = 90.0 + $itor({$random(seed)} % 220);
                            a = $itor({$random(seed)} % 4000);
                            if (({$random(seed)} % 4) == 0) a = 0.0;      // pauses
                        end
                        env = 0.95 * env + 0.05 * a;
                        x = env * ($sin(ph) + 0.5*$sin(2.0*ph) + 0.25*$sin(3.0*ph))
                            + $itor($random(seed) % 17);
                        ph = ph + 2.0*PI*f/16000.0;
                    end
                    7: begin x = p1 * $sin(ph); ph = ph + 2.0*PI*150.0/16000.0; end // near-threshold sine
                    default: x = 0.0;
                endcase
                push($rtoi(x), spacing_fn(smode));
            end
        end
    endtask

    initial begin
        for (i = 0; i < 16; i = i + 1) begin seg_frames[i] = 0; seg_voiced[i] = 0; end
        ph = 0.0; env = 0.0; f = 150.0; a = 0.0;
        repeat (10) @(posedge clk);
        rst_n <= 1'b1;
        repeat (5) @(posedge clk);
        segment(0, 12, 0, 0.0);
        segment(1, 12, 0, 0.0);
        segment(3, 12, 0, 3000.0);
        segment(0, 4, 0, 0.0);
        segment(2, 12, 0, 9.0);      // noise near threshold
        segment(2, 12, 0, 11.0);
        segment(7, 10, 0, 60.0);     // sine amp 60: r0 ~ 460k (around 512<<10)
        segment(7, 10, 0, 66.0);
        // S_R0 reads each sample twice (smp_idx advances from smp_idx_r), so the
        // gate sits near sine amplitude ~45 / noise scale ~7: sweep around it.
        segment(7, 6, 0, 42.0);
        segment(7, 6, 0, 44.0);
        segment(7, 6, 0, 45.0);
        segment(7, 6, 0, 46.0);
        segment(7, 6, 0, 48.0);
        segment(2, 8, 0, 6.5);
        segment(2, 8, 0, 7.0);
        segment(2, 8, 0, 7.5);
        segment(4, 12, 0, 3000.0);
        segment(1, 6, 0, 0.0);
        segment(5, 12, 0, 3000.0);
        segment(0, 6, 0, 0.0);
        segment(6, 40, 0, 0.0);
        segment(5, 4, 0, 200.0);
        segment(0, 4, 0, 0.0);
        segment(6, 30, 0, 0.0);
        segment(0, 6, 2, 0.0);       // overrun cadence: frame_start during busy FSM
        segment(6, 10, 2, 0.0);
        segment(3, 6, 2, 3000.0);
        segment(0, 3, 1, 0.0);       // real 16 kHz cadence
        segment(4, 3, 1, 3000.0);
        segment(1, 3, 1, 0.0);
        repeat (60000) @(posedge clk);
        $display("RESULT cycles=%0d mismatch_cycles=%0d first_mismatch_cycle=%0d state_mismatch_cycles=%0d",
                 cycles, mismatch, first_mm, state_mm);
        $display("RESULT frames_done ref=%0d new=%0d silent(r0<thr)=%0d voiced=%0d",
                 frames_ref, frames_new, silent_frames, voiced_frames);
        for (i = 0; i < 8; i = i + 1)
            $display("RESULT kind %0d: frames_done=%0d voiced=%0d", i, seg_frames[i], seg_voiced[i]);
        $display("RESULT near_threshold frames (r0[35:10] in 448..576)=%0d of which r0<thr=%0d", near_thr, near_thr_silent);
        $display("RESULT silent_lag_cycles=%0d", gated_cycles);
        $display("RESULT silent_lag ma_a+ma_b bit toggles: ref=%0d new=%0d", tog_ma_ref_s, tog_ma_new_s);
        $display("RESULT silent_lag ra_r+rb_r bit toggles: ref=%0d new=%0d", tog_rd_ref_s, tog_rd_new_s);
        $display("RESULT silent_lag acc bit toggles: ref=%0d new=%0d", tog_acc_ref_s, tog_acc_new_s);
        $display("RESULT whole-run ma_a+ma_b bit toggles: ref=%0d new=%0d", tog_ma_ref_all, tog_ma_new_all);
        $finish;
    end
endmodule
