`timescale 1ns/1ps
// External boundaries only. All controller, decoder, FIFO, UI and pixel RTL is real.
module sys_pll(input refclk,reset,output clk0_out,clk1_out,clk2_out,locked);
    reg sd=0,mem=0;always #5 sd=~sd;always #4 mem=~mem;
    assign clk0_out=sd;assign clk1_out=mem;assign clk2_out=~mem;assign locked=!reset;
endmodule
module video_pll(input refclk,reset,output clk0_out,clk1_out,locked);
    reg vc=0,hc=0;always #20 vc=~vc;always #4 hc=~hc;
    assign clk0_out=vc;assign clk1_out=hc;assign locked=!reset;
endmodule
module PLL_HDMI_AUDIO(input refclk,reset,output extlock,clk0_out,clk1_out,clk2_out);
    reg ac=0;always #40.69 ac=~ac;
    assign clk0_out=0;assign clk1_out=0;assign clk2_out=ac;assign extlock=!reset;
endmodule
module sdram(input Clk,Clk_sft,Rst,output Sdr_init_done,Sdr_init_ref_vld,Sdr_busy,
    input App_wr_en,input [20:0] App_wr_addr,input [3:0] App_wr_dm,input [31:0] App_wr_din,
    input App_rd_en,input [20:0] App_rd_addr,output reg Sdr_rd_en,output reg [31:0] Sdr_rd_dout);
    integer read_run=0,write_run=0;
    always @(posedge Clk)begin
        if(Rst)begin read_run=0;write_run=0;end
        else begin
            if(App_rd_en)begin
                if(read_run==0 && App_rd_addr[1:0]!=0)$fatal(1,"UNALIGNED_BL4_READ");
                read_run=read_run+1;
            end else if(read_run!=0)begin
                if(read_run%4!=0)$fatal(1,"INCOMPLETE_BL4_READ words=%0d",read_run);
                read_run=0;
            end
            if(App_wr_en)begin
                if(write_run==0 && App_wr_addr[1:0]!=0)$fatal(1,"UNALIGNED_BL4_WRITE");
                write_run=write_run+1;
            end else if(write_run!=0)begin
                if(write_run%4!=0)$fatal(1,"INCOMPLETE_BL4_WRITE words=%0d",write_run);
                write_run=0;
            end
        end
    end
    reg [31:0] memory[0:2097151];
    reg [7:0] latency=0;reg [20:0] address[0:7];
    integer cycle=0,j,writes=0,reads=0,cache_writes=0;
    assign Sdr_init_done=!Rst;
    assign Sdr_busy=cycle%997<12;assign Sdr_init_ref_vld=Sdr_busy;
    always @(posedge Clk)begin
        if(Rst)begin latency<=0;Sdr_rd_en<=0;cycle<=0;end
        else begin
            cycle<=cycle+1;latency<={latency[6:0],App_rd_en};address[0]<=App_rd_addr;
            for(j=1;j<8;j=j+1)address[j]<=address[j-1];
            Sdr_rd_en<=latency[7];if(latency[7])Sdr_rd_dout<=memory[address[7]];
            if(App_wr_en)begin
                if(App_wr_dm!==0)$fatal(1,"MODEL_UNEXPECTED_WRITE_MASK");
                if(App_rd_en)$fatal(1,"MODEL_SIMULTANEOUS_COMMANDS");
                memory[App_wr_addr]<=App_wr_din;writes=writes+1;
                if(App_wr_addr>=21'h1c2000)cache_writes=cache_writes+1;
            end
            if(App_rd_en)reads=reads+1;
        end
    end
endmodule
// Sector service for the SPI controller boundary. A 512-byte reply has genuine
// request / busy / end sequencing; the original bmp_read handles every byte.
module sd_card_top #(parameter SPI_LOW_SPEED_DIV=248,SPI_HIGH_SPEED_DIV=0)(
    input clk,rst,output SD_nCS,SD_DCLK,SD_MOSI,input SD_MISO,
    output reg sd_init_done,input sd_sec_read,input [31:0] sd_sec_read_addr,
    output reg [7:0] sd_sec_read_data,output reg sd_sec_read_data_valid,sd_sec_read_end,
    input sd_sec_write,input [31:0] sd_sec_write_addr,input [7:0] sd_sec_write_data,
    output sd_sec_write_data_req,sd_sec_write_end);
    reg [7:0] card[0:5532671]; // 6 * 1801 sectors * 512 bytes
    initial $readmemh("reference/card_bytes.mem",card);
    reg active=0,request_seen=0;reg [31:0] sector;integer pos=0,delay_count=0,requests=0;
    assign SD_nCS=!active;assign SD_DCLK=clk;assign SD_MOSI=0;
    assign sd_sec_write_data_req=0;assign sd_sec_write_end=0;
    always @(posedge clk)begin
        if(rst)begin active<=0;request_seen<=0;sd_init_done<=0;sd_sec_read_data_valid<=0;sd_sec_read_end<=0;delay_count<=0;end
        else begin
            sd_init_done<=1;sd_sec_read_data_valid<=0;sd_sec_read_end<=0;
            if(!sd_sec_read)request_seen<=0;
            if(sd_sec_write)$fatal(1,"UNAUTHORIZED_CARD_WRITE");
            if(!active && sd_sec_read && !request_seen)begin
                sector<=sd_sec_read_addr;pos<=0;active<=1;delay_count<=8;request_seen<=1;requests=requests+1;
            end else if(active && delay_count!=0)delay_count<=delay_count-1;
            else if(active && pos<512)begin
                sd_sec_read_data<=sector<10806?card[sector*512+pos]:8'd0;
                sd_sec_read_data_valid<=1;pos<=pos+1;
            end else if(active)begin active<=0;sd_sec_read_end<=1;end
        end
    end
endmodule
