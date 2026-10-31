`timescale 1ns/1ps
// Cache-generation-only font reader. Coordinates are held until advance.
// T10: the line/row window decode is registered (one cycle after x/y) and
// row*5 one cycle later; glyph*100 is registered when metadata is decoded.
// The builder holds x/y for >=4 cycles (GEO1..GEO4) before request, and still
// holds the old x/y on the advance cycle, so all registered values match the
// current coordinates whenever request/advance/ready/ink are used.
module thumbnail_text_serial(
    input clk, input rst, input request, input advance, input cancel,
    input [9:0] x, input [8:0] y, output ready, output [23:0] rgb,
    output ink, output [1:0] label_slot, output reg [12:0] font_addr, input [3:0] font_data
);
    wire y_l0 = (y >= 9'd68 && y < 9'd88);
    wire y_l1 = (y >= 9'd98 && y < 9'd118);
    wire y_l2 = (y >= 9'd307 && y < 9'd327);
    wire x_c0 = (x >= 10'd64 && x < 10'd208);
    wire x_c1 = (x >= 10'd248 && x < 10'd392);
    wire x_c2 = (x >= 10'd432 && x < 10'd576);

    reg [2:0] line_id_d; reg [4:0] row_d; reg line_valid_d;
    always @* begin
        line_id_d = 3'd0; row_d = 5'd0; line_valid_d = 1'b0;
        if(y_l0 && x >= 10'd280 && x < 10'd360) begin line_id_d = 3'd0; row_d = y[4:0] - 5'd4; line_valid_d = 1'b1; end
        else if(y_l1 && x >= 10'd45 && x < 10'd595) begin line_id_d = 3'd1; row_d = y[4:0] - 5'd2; line_valid_d = 1'b1; end
        else if(y_l2) begin
            if(x_c0) begin line_id_d = 3'd2; row_d = y[4:0] - 5'd19; line_valid_d = 1'b1; end
            else if(x_c1) begin line_id_d = 3'd3; row_d = y[4:0] - 5'd19; line_valid_d = 1'b1; end
            else if(x_c2) begin line_id_d = 3'd4; row_d = y[4:0] - 5'd19; line_valid_d = 1'b1; end
        end
    end
    reg [2:0] line_id; reg [4:0] row; reg line_valid;
    reg [12:0] row_offset;
    always @(posedge clk or posedge rst)
        if(rst) begin line_id <= 0; row <= 0; line_valid <= 0; row_offset <= 0; end
        else begin
            line_id <= line_id_d; row <= row_d; line_valid <= line_valid_d;
            row_offset <= ({8'd0, row} << 2) + row;
        end

    reg [5:0] cell_index;
    reg [12:0] glyph_base;
    reg [4:0] col, width;
    reg [3:0] state;
    reg [1:0] part;
    reg [12:0] meta_addr;
    reg [11:0] metadata;
    reg pixel_ink;
    wire [12:0] cell_no = {line_id, cell_index};
    assign ready = !line_valid || state == 8;
    assign ink = line_valid && state == 8 && pixel_ink;
    assign label_slot = line_id >= 2 ? line_id - 2 : 2'd3;
    assign rgb = !ink ? 24'd0 : line_id == 0 ? 24'h1e3a8a : 24'h334155;

    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state <= 0; cell_index <= 0; col <= 0; width <= 6; glyph_base <= 0;
            part <= 0; meta_addr <= 0; metadata <= 0; pixel_ink <= 0; font_addr <= 0;
        end else if(cancel) begin
            state <= 0; cell_index <= 0; col <= 0;
        end else if(advance) begin
            state <= 0;
            if(!line_valid) begin cell_index <= 0; col <= 0; end
            else if(col == width - 1) begin col <= 0; cell_index <= cell_index + 1'b1; end
            else col <= col + 1'b1;
        end else case(state)
            0: if(request && line_valid) begin
                if(col == 0) begin
                    meta_addr <= 13'd4500 + (cell_no << 1) + cell_no;
                    part <= 0; state <= 1;
                end else begin
                    font_addr <= glyph_base + row_offset + col[4:2];
                    state <= 5;
                end
            end
            1: begin
                font_addr <= meta_addr;
                state <= 7;
            end
            7: state <= 2;
            2: begin
                metadata[part*4+:4] <= font_data;
                if(part == 2) state <= 3;
                else begin
                    part <= part + 1'b1;
                    font_addr <= meta_addr + part + 1'b1;
                    state <= 7;
                end
            end
            3: begin
                glyph_base <= ({7'd0, metadata[5:0]} << 6) + ({7'd0, metadata[5:0]} << 5) + ({7'd0, metadata[5:0]} << 2);
                width <= metadata[10:6]; state <= 4;
            end
            4: begin font_addr <= glyph_base + row_offset + col[4:2]; state <= 5; end
            5: state <= 6;
            6: begin pixel_ink <= font_data[col[1:0]]; state <= 8; end
            8: begin end
            default: state <= 0;
        endcase
    end
endmodule
