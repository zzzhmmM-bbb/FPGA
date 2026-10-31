`timescale 1ns/1ps
// T4 two-score step-1 candidate. Four linear envelope segments, Q16 recurrence.
// Score 0..127, pitch increments 128..157, envelope parameters 256..479,
// voice state 480..503 (phase lo/hi, inc lo/hi, env lo/hi, count, pointer),
// half-beat counter 504. No top-level/I2S integration or timing claim.
module forest_linear_budget #(
    parameter HOLD_PCM_ON_PAUSE = 0
) (
    input wire clk, rst, sample_ce, pause, song,
    output wire song_ready,
    output reg signed [23:0] pcm,
    output wire busy
);
    localparam INIT=0, IDLE=1, FRAME_WAIT=2, FRAME_CAP=3, FRAME_WRITE=4,
        NOTE_WAIT=5, NOTE_CAP=6, SELECT=7, PITCH_WAIT=8, PITCH_LOW=9,
        INC_LOW_WRITE=10, HIGH_WAIT=11, PITCH_HIGH=12, INC_HIGH_WRITE=13,
        CLEAR_PL=14, CLEAR_PH=15, CLEAR_EL=16, CLEAR_EH=17, PTR_INIT=18,
        INIT_LEN_WAIT=19, INIT_LEN_CAP=20, INIT_COUNT=21, SCORE_NEXT=22,
        PL_WAIT=23, PL_CAP=24, IL_WAIT=25, PL_ADD=26,
        PH_WAIT=27, PH_CAP=28, IH_WAIT=29, PH_ADD=30,
        WL_WAIT=31, WL_CAP=32, WH_WAIT=33, W_CAP=34,
        PTR_WAIT=35, PTR_CAP=36, COUNT_WAIT=37, COUNT_CAP=38, COUNT_WRITE=39,
        PTR_ADVANCE=40, START_WAIT=41, START_CAP=42, START_WRITE=43,
        START_CLEAR=44, LEN_WAIT=45, LEN_CAP=46, LEN_WRITE=47,
        EL_WAIT=48, EL_CAP=49, DL_WAIT=50, EL_ADD=51,
        EH_WAIT=52, EH_CAP=53, DH_WAIT=54, EH_ADD=55,
        MIX=56, NEXT=57, VOICE_NEXT=58, FINISH=59, SILENT_EL=60, SILENT_EH=61;
    reg [5:0] state;
    reg [4:0] init_index;
    reg [1:0] voice, fractional_step;
    reg [6:0] beat_index;
    reg active_song;
    wire song_restart = sample_ce && state==IDLE && song!=active_song;
    wire score_last = (&beat_index[5:0]) && (active_song || beat_index[6]);
    assign song_ready = song==active_song && state!=INIT;
    always @(posedge clk) begin
        if(rst) active_song<=1'b0;
        else if(song_restart) active_song<=song;
    end
    reg [11:0] notes;
    reg [5:0] profiles;
    reg [15:0] accumulator;
    reg carry, count_empty;
    reg [8:0] pointer, wave_address;
    reg signed [11:0] wave_value;
    reg signed [28:0] product;
    reg signed [17:0] mix;
    (* ram_style="bram" *) reg [17:0] score_state [0:511];
    (* rom_style="bram" *) reg [17:0] wave_rom [0:511];
    initial begin
        $readmemh("score_packed.hex",score_state);
        $readmemh("wave_packed.hex",wave_rom);
    end
    reg [17:0] ram_q, wave_q;
    reg [2:0] field;
    reg [8:0] ram_address;
    wire [3:0] profile = voice==0 ? profiles[3:0] :
        voice==1 ? {3'b101,profiles[4]} : {3'b110,profiles[5]};
    wire [8:0] profile_base = {1'b1,profile,4'b0};
    wire [8:0] state_address = {4'b1111,voice,field};
    always @(*) begin
        case(state)
            PL_CAP,IL_WAIT,INC_LOW_WRITE: field=2;
            PH_WAIT,PH_ADD,CLEAR_PH: field=1;
            PH_CAP,IH_WAIT,INC_HIGH_WRITE: field=3;
            CLEAR_EL,START_CLEAR,EL_WAIT,EL_ADD,SILENT_EL: field=4;
            CLEAR_EH,START_WRITE,EH_WAIT,EH_ADD,SILENT_EH: field=5;
            INIT_COUNT,COUNT_WAIT,COUNT_CAP,COUNT_WRITE,LEN_WRITE: field=6;
            PTR_INIT,PTR_WAIT,PTR_CAP,PTR_ADVANCE: field=7;
            default: field=0;
        endcase
    end
    always @(*) begin
        case(state)
            INIT: ram_address={4'b1111,init_index};
            FRAME_WAIT,FRAME_CAP,FRAME_WRITE: ram_address=504;
            NOTE_WAIT,NOTE_CAP: ram_address={1'b0,active_song,(active_song | beat_index[6]),beat_index[5:0]};
            PITCH_WAIT,PITCH_LOW: ram_address={4'b0100,notes[3:0],1'b0};
            HIGH_WAIT,PITCH_HIGH: ram_address={4'b0100,notes[3:0],1'b1};
            INIT_LEN_WAIT,INIT_LEN_CAP,LEN_WAIT,LEN_CAP: ram_address={pointer[8:2],2'd2};
            START_WAIT,START_CAP: ram_address={pointer[8:2],2'd3};
            EL_CAP,DL_WAIT: ram_address={pointer[8:2],2'd0};
            EH_CAP,DH_WAIT: ram_address={pointer[8:2],2'd1};
            default: ram_address=state_address;
        endcase
    end
    wire [15:0] operand = state==FRAME_WRITE ? 16'd1 :
        (state==COUNT_WRITE || state==LEN_WRITE) ? 16'hffff :
        state==PTR_ADVANCE ? 16'd4 :
        state==NEXT ? product[26:11] : ram_q[15:0];
    wire [16:0] sum = {1'b0,accumulator}+{1'b0,operand}+
        ((state==PH_ADD || state==EH_ADD) && carry);
    wire signed [17:0] scaled_product = product >>> 11;
    wire [2:0] mix_high = {1'b0,mix[17:16]}+{1'b0,scaled_product[17:16]}+sum[16];
    wire frame_last = accumulator == ((fractional_step==1)?16'd13333:16'd13332);
    wire clear_word = state==INIT || state==CLEAR_PL || state==CLEAR_PH ||
        state==CLEAR_EL || state==CLEAR_EH || state==START_CLEAR ||
        state==SILENT_EL || state==SILENT_EH || (state==FRAME_WRITE && frame_last);
    wire copy_word = state==INC_LOW_WRITE || state==INC_HIGH_WRITE ||
        state==PTR_INIT || state==INIT_COUNT || state==START_WRITE;
    wire ram_write = !rst && !pause && (clear_word || copy_word ||
        state==FRAME_WRITE || state==PL_ADD || state==PH_ADD ||
        (state==COUNT_WRITE && !count_empty) || state==PTR_ADVANCE ||
        state==LEN_WRITE || state==EL_ADD || state==EH_ADD);
    wire [15:0] write_result = ({16{!clear_word && !copy_word}} & sum[15:0]) |
        ({16{!clear_word && copy_word}} & accumulator);
    always @(posedge clk) begin
        if(!pause) ram_q<=score_state[ram_address];
        if(ram_write) score_state[ram_address]<={2'b0,write_result};
        if(!pause) wave_q<=wave_rom[wave_address];
    end
    assign busy = state!=IDLE;
    always @(posedge clk) begin
        if(rst || song_restart) begin
            state<=INIT; init_index<=0; voice<=0; fractional_step<=0;
            beat_index<=0; notes<=0; profiles<=0; accumulator<=0;
            carry<=0; count_empty<=0; pointer<=0; wave_address<=0;
            wave_value<=0; product<=0; mix<=0; pcm<=0;
        end else if(pause) begin
            if(!HOLD_PCM_ON_PAUSE) pcm<=0;
        end
        else case(state)
            INIT: if(init_index==31) state<=IDLE; else init_index<=init_index+1'b1;
            IDLE: if(sample_ce) begin voice<=0; mix<=0; state<=FRAME_WAIT; end
            FRAME_WAIT: state<=FRAME_CAP;
            FRAME_CAP: begin accumulator<=ram_q[15:0]; state<=FRAME_WRITE; end
            FRAME_WRITE: begin
                if(frame_last) begin
                    beat_index<=beat_index+1'b1;
                    fractional_step<=score_last || fractional_step==2 ? 0 : fractional_step+1'b1;
                end
                state<=accumulator==0 ? NOTE_WAIT : PL_WAIT;
            end
            NOTE_WAIT: state<=NOTE_CAP;
            NOTE_CAP: begin notes<=ram_q[11:0]; profiles<=ram_q[17:12]; state<=SELECT; end
            SELECT: state<=notes[3:0]==0 ? SCORE_NEXT : PITCH_WAIT;
            PITCH_WAIT: state<=PITCH_LOW;
            PITCH_LOW: begin accumulator<=ram_q[15:0]; state<=INC_LOW_WRITE; end
            INC_LOW_WRITE: state<=HIGH_WAIT;
            HIGH_WAIT: state<=PITCH_HIGH;
            PITCH_HIGH: begin accumulator<=ram_q[15:0]; state<=INC_HIGH_WRITE; end
            INC_HIGH_WRITE: state<=CLEAR_PL;
            CLEAR_PL: state<=CLEAR_PH;
            CLEAR_PH: state<=CLEAR_EL;
            CLEAR_EL: state<=CLEAR_EH;
            CLEAR_EH: begin accumulator<={7'b0,profile_base}; pointer<=profile_base; state<=PTR_INIT; end
            PTR_INIT: state<=INIT_LEN_WAIT;
            INIT_LEN_WAIT: state<=INIT_LEN_CAP;
            INIT_LEN_CAP: begin accumulator<=ram_q[15:0]; state<=INIT_COUNT; end
            INIT_COUNT: state<=SCORE_NEXT;
            SCORE_NEXT: if(voice==2) begin voice<=0; state<=PL_WAIT; end
                else begin voice<=voice+1'b1; notes<={4'b0,notes[11:4]}; state<=SELECT; end
            PL_WAIT: state<=PL_CAP;
            PL_CAP: begin accumulator<=ram_q[15:0]; state<=IL_WAIT; end
            IL_WAIT: state<=PL_ADD;
            PL_ADD: begin carry<=sum[16]; state<=PH_WAIT; end
            PH_WAIT: state<=PH_CAP;
            PH_CAP: begin accumulator<=ram_q[15:0]; state<=IH_WAIT; end
            IH_WAIT: state<=PH_ADD;
            PH_ADD: begin wave_address<={sum[15:8],1'b0}; state<=WL_WAIT; end
            WL_WAIT: state<=WL_CAP;
            WL_CAP: begin
                if(voice==0) wave_value<=wave_q[11:0];
                else if(voice==1) wave_value<={6'b0,wave_q[17:12]};
                wave_address[0]<=1'b1; state<=WH_WAIT;
            end
            WH_WAIT: state<=W_CAP;
            W_CAP: begin
                if(voice==1) wave_value<={wave_q[5:0],wave_value[5:0]};
                else if(voice==2) wave_value<=wave_q[17:6];
                state<=PTR_WAIT;
            end
            PTR_WAIT: state<=PTR_CAP;
            PTR_CAP: begin pointer<=ram_q[8:0]; state<=COUNT_WAIT; end
            COUNT_WAIT: state<=COUNT_CAP;
            COUNT_CAP: begin accumulator<=ram_q[15:0]; count_empty<=ram_q[15:0]==0; state<=COUNT_WRITE; end
            COUNT_WRITE: begin
                accumulator<={7'b0,pointer};
                state<=!count_empty ? EL_WAIT : (!pointer[8] || pointer[3:2]==3) ? SILENT_EL : PTR_ADVANCE;
            end
            PTR_ADVANCE: begin pointer<=sum[8:0]; state<=START_WAIT; end
            START_WAIT: state<=START_CAP;
            START_CAP: begin accumulator<=ram_q[15:0]; state<=START_WRITE; end
            START_WRITE: state<=START_CLEAR;
            START_CLEAR: state<=LEN_WAIT;
            LEN_WAIT: state<=LEN_CAP;
            LEN_CAP: begin accumulator<=ram_q[15:0]; state<=LEN_WRITE; end
            LEN_WRITE: state<=EL_WAIT;
            EL_WAIT: state<=EL_CAP;
            EL_CAP: begin accumulator<=ram_q[15:0]; state<=DL_WAIT; end
            DL_WAIT: state<=EL_ADD;
            EL_ADD: begin carry<=sum[16]; state<=EH_WAIT; end
            EH_WAIT: state<=EH_CAP;
            EH_CAP: begin
                accumulator<=ram_q[15:0];
                product<=wave_value*$signed({1'b0,ram_q[15:0]}); state<=DH_WAIT;
            end
            DH_WAIT: state<=EH_ADD;
            EH_ADD: state<=MIX;
            MIX: begin accumulator<=mix[15:0]; state<=NEXT; end
            NEXT: begin mix<={mix_high[1:0],sum[15:0]}; state<=VOICE_NEXT; end
            SILENT_EL: state<=SILENT_EH;
            SILENT_EH: state<=VOICE_NEXT;
            VOICE_NEXT: if(voice==2) state<=FINISH;
                else begin voice<=voice+1'b1; state<=PL_WAIT; end
            FINISH: begin pcm<={mix[15:0],8'b0}; state<=IDLE; end
            default: state<=INIT;
        endcase
    end
endmodule
