


`define   DATA_WIDTH                        32
`define   ADDR_WIDTH                        21
`define   DM_WIDTH                          4

`define   ROW_WIDTH                        11
`define   BA_WIDTH                        2

`define	  SDR_CLK_PERIOD				1000000000/125000000
// v28: EM638325 needs 4096 refresh / 64 ms -> 1953 clk @125 MHz = 15.6 us.
// The old form 64000000/`SDR_CLK_PERIOD/2**(`ROW_WIDTH) expanded to 0 (no refresh).
`define   SELF_REFRESH_INTERVAL			(64000000/(1000000000/125000000)/4096)

