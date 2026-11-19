`timescale 1ns/1ps
// Simple dual-port synchronous 4096 x 16 RAM.
// Port A: internal write port. Port B: external synchronous read port.
module sdp_bram_4096x16 (
    input  wire        clk,
    input  wire        we_a,
    input  wire [11:0] addr_a,
    input  wire [15:0] din_a,
    input  wire        en_b,
    input  wire [11:0] addr_b,
    output reg  [15:0] dout_b
);
    (* ram_style = "block" *) reg [15:0] mem [0:4095];

    always @(posedge clk) begin
        if (we_a)
            mem[addr_a] <= din_a;
        if (en_b)
            dout_b <= mem[addr_b];
    end
endmodule
