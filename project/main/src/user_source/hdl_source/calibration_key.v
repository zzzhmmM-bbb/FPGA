module calibration_key #(
    parameter integer DEBOUNCE_CYCLES = 500000,
    parameter integer LONG_CYCLES = 50000000,
    // Existing 20 ms debounce defaults give a 1 ms enable in either clock domain.
    parameter integer SAMPLE_CYCLES = (DEBOUNCE_CYCLES < 25000) ? 1 : DEBOUNCE_CYCLES / 20
) (
    input  wire clk,
    input  wire rst_n,
    input  wire key_n,
    output reg  short_press,
    output reg  long_press
);

    localparam integer DB_TICKS = (DEBOUNCE_CYCLES + SAMPLE_CYCLES - 1) / SAMPLE_CYCLES;
    localparam integer LONG_TICKS = (LONG_CYCLES + SAMPLE_CYCLES - 1) / SAMPLE_CYCLES;
    localparam integer DEBOUNCE_WIDTH = (DB_TICKS > 1) ? $clog2(DB_TICKS) : 1;
    localparam integer LONG_WIDTH = (LONG_TICKS > 1) ? $clog2(LONG_TICKS) : 1;
    wire sample_tick;
    generate
        if (SAMPLE_CYCLES == 1) begin : g_each_cycle
            assign sample_tick = 1'b1;
        end else begin : g_millisecond
            localparam integer TW = $clog2(SAMPLE_CYCLES);
            reg [TW-1:0] tick_count;
            assign sample_tick = (tick_count == SAMPLE_CYCLES - 1);
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) tick_count <= 0;
                else if (sample_tick) tick_count <= 0;
                else tick_count <= tick_count + 1'b1;
            end
        end
    endgenerate

    reg key_meta;
    reg key_sync;
    reg key_stable;
    reg key_stable_d;
    reg [DEBOUNCE_WIDTH-1:0] debounce_count;
    reg [LONG_WIDTH-1:0] long_count;
    reg long_fired;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_meta       <= 1'b1;
            key_sync       <= 1'b1;
            key_stable     <= 1'b1;
            key_stable_d   <= 1'b1;
            debounce_count <= 0;
            long_count     <= 0;
            long_fired     <= 1'b0;
            short_press    <= 1'b0;
            long_press     <= 1'b0;
        end else begin
            key_meta     <= key_n;
            key_sync     <= key_meta;
            key_stable_d <= key_stable;
            short_press  <= 1'b0;
            long_press   <= 1'b0;

            if (key_sync == key_stable) begin
                debounce_count <= 0;
            end else if (sample_tick && debounce_count == DB_TICKS - 1) begin
                key_stable     <= key_sync;
                debounce_count <= 0;
            end else if (sample_tick) begin
                debounce_count <= debounce_count + 1'b1;
            end

            if (!key_stable) begin
                if (!long_fired) begin
                    if (sample_tick && long_count == LONG_TICKS - 1) begin
                        long_press <= 1'b1;
                        long_fired <= 1'b1;
                    end else if (sample_tick) begin
                        long_count <= long_count + 1'b1;
                    end
                end
            end else begin
                if (!key_stable_d && !long_fired)
                    short_press <= 1'b1;
                long_count <= 0;
                long_fired <= 1'b0;
            end
        end
    end

endmodule
