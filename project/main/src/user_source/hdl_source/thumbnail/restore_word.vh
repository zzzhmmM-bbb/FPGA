function [15:0] restore_word;input [14:0] address;input [15:0] word_in;reg [15:0] v;integer k;begin
v=0;for(k=0;k<4;k=k+1)begin case(word_in[k*3+:3])
3'd0:v[k*4+:4]=4'h0;
3'd1:v[k*4+:4]=4'h4;
3'd2:v[k*4+:4]=4'h5;
3'd3:v[k*4+:4]=4'h8;
3'd4:v[k*4+:4]=4'hc;
3'd5:v[k*4+:4]=4'hd;
3'd6:v[k*4+:4]=4'he;
3'd7:v[k*4+:4]=4'hf;
endcase end
case(address)
15'd9115:v=16'hffb6;
15'd9116:v=16'hff3b;
15'd9117:v=16'hfb7f;
15'd9180:v=16'hbffd;
15'd9181:v=16'hbf11;
15'd9182:v=16'hf703;
15'd9183:v=16'hb10b;
15'd9247:v=16'hffa6;
15'd9248:v=16'hfb27;
15'd9249:v=16'hfb7f;
default:begin end endcase
restore_word=address>=24512?word_in:v;end endfunction
