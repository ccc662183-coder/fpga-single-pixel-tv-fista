`timescale 1ns / 1ps
// Stage-2A adapter for the existing 4096-point in-place FWHT core.
// The core stores signed S32.F11 values. Q5.11 image samples must be
// sign-extended to 32 bits by the upstream loader before being written.
module fwht_q11_stage2 #(
    parameter integer LOG2_POINTS = 12
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         start,
    output wire                         ready,
    output wire                         done,

    input  wire                         ext_we,
    input  wire [LOG2_POINTS-1:0]       ext_addr,
    input  wire signed [31:0]           ext_wdata_s32,

    output wire signed [31:0]           ext_rdata_raw_s32,
    output wire signed [31:0]           ext_rdata_norm_s32
);
    fwht_inplace #(
        .LOG2_POINTS(LOG2_POINTS),
        .POINTS(1 << LOG2_POINTS),
        .DATA_WIDTH(32)
    ) u_fwht_inplace (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .ready(ready),
        .done(done),
        .ext_we(ext_we),
        .ext_addr(ext_addr),
        .ext_wdata(ext_wdata_s32),
        .ext_rdata(ext_rdata_raw_s32)
    );

    // W = H_4096 / 64. Arithmetic shift is intentional: negative values
    // round toward negative infinity, matching the Python model's >> 6.
    assign ext_rdata_norm_s32 = ext_rdata_raw_s32 >>> 6;
endmodule
