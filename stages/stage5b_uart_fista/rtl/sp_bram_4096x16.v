`timescale 1ns/1ps
// Single-port synchronous 4096 x 16 RAM.
// No reset on the memory array: this coding style is intended for BRAM inference.
module sp_bram_4096x16 (
    input  wire        clk,
    input  wire        en,
    input  wire        we,
    input  wire [11:0] addr,
    input  wire [15:0] din,
    output reg  [15:0] dout
);
    (* ram_style = "block" *) reg [15:0] mem [0:4095];

    always @(posedge clk) begin
        if (en) begin
            if (we)
                mem[addr] <= din;
            else
                dout <= mem[addr];
        end
    end
endmodule
