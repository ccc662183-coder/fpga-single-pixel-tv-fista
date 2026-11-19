`timescale 1ns / 1ps
// Stage 5A TV primitives -- NOT a complete TV-FISTA implementation.
// Input: one pixel and neighbors, plus 12-bit TV dual field and neighbors.
// Gradient: forward difference with zero gradient at right/bottom edges.
// Divergence: boundary-conditioned negative adjoint of the gradient.
module tv_grad_div_pixel (
    input wire clk, rst_n, valid_in,
    input wire [7:0] x_center, x_right, x_down,
    input wire signed [11:0] px_center, px_left, py_center, py_up,
    input wire at_left, at_right, at_top, at_bottom,
    output reg valid_out,
    output reg signed [9:0] grad_x, grad_y,
    output reg signed [15:0] divergence
);
    wire signed [9:0] xc = $signed({2'b00,x_center});
    wire signed [9:0] xr = $signed({2'b00,x_right});
    wire signed [9:0] xd = $signed({2'b00,x_down});
    wire signed [9:0] gx = at_right  ? 10'sd0 : xr-xc;
    wire signed [9:0] gy = at_bottom ? 10'sd0 : xd-xc;
    wire signed [15:0] pxc = {{4{px_center[11]}},px_center};
    wire signed [15:0] pxl = {{4{px_left[11]}},px_left};
    wire signed [15:0] pyc = {{4{py_center[11]}},py_center};
    wire signed [15:0] pyu = {{4{py_up[11]}},py_up};
    wire signed [15:0] d = (at_right ? 16'sd0:pxc)
                         - (at_left ? 16'sd0:pxl)
                         + (at_bottom ? 16'sd0:pyc)
                         - (at_top ? 16'sd0:pyu);
    always @(posedge clk) begin
        if(!rst_n) begin
            valid_out <= 1'b0;
            grad_x <= 10'sd0;
            grad_y <= 10'sd0;
            divergence <= 16'sd0;
        end else begin
            valid_out <= valid_in;
            if(valid_in) begin
                grad_x <= gx;
                grad_y <= gy;
                divergence <= d;
            end
        end
    end
endmodule
