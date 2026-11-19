`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// Stage-2B: 4096-point data-consistency gradient step, all in PL.
// Fixed-point contract (Stage-0.2):
//   z: signed S16.F11 (Q5.11), 4096 pixels
//   y: signed S32.F11, 1024 measured FWHT coefficients
//   W = H_4096 / 64; each normalized FWHT uses arithmetic >>> 6
//   residual[i] = mask[i] ? ((H*z)[i] >>> 6) - y[rank(i)] : 0
//   grad = (H*residual) >>> 6
//   v = z - grad, signed S16.F11
// IMPORTANT: perform residual/adjoint subtraction, not coefficient replacement,
// because finite-precision shifts do not preserve exact mathematical equivalence.
//
// Memory architecture (each 4096-depth block is BRAM-friendly):
//   existing unchanged FWHT core: 4096 x 32, in-place
//   z_mem:                   4096 x 16, single-port synchronous
//   result_mem:              4096 x 16, simple dual-port synchronous
//   measured_y:              1024 x 32, single-port synchronous
//   mask_rom:                4096 x 1, fixed read-only low-sequency pattern
// One FWHT core is reused sequentially for the forward and adjoint passes.
//
// Runtime load protocol (only when ready=1):
//   load_kind=0 -> image pixel, load_addr 0..4095, load_data[15:0] Q5.11
//   load_kind=1 -> measurement, load_addr 0..1023, load_data signed S32.F11
// Measurements must be packed by ascending mask position.
// Output read is synchronous: read_data/read_valid after posedge with read_en.
// The module is a computational IP, not an AX7020 board top or UART design.
// -----------------------------------------------------------------------------
module data_consistency_q11 (
    input wire clk,
    input wire rst_n,
    input wire start,
    output wire ready,
    output wire busy,
    output reg done,
    output reg range_error,

    input wire load_we,
    input wire load_kind,
    input wire [11:0] load_addr,
    input wire signed [31:0] load_data,

    input wire read_en,
    input wire [11:0] read_addr,
    output reg read_valid,
    output reg signed [15:0] read_data
);
    localparam [3:0]
        S_IDLE         = 4'd0,
        S_FORWARD_GO   = 4'd1,
        S_FORWARD_WAIT = 4'd2,
        S_RES_READ     = 4'd3,
        S_RES_CAPTURE  = 4'd4,
        S_RES_WRITE    = 4'd5,
        S_ADJOINT_GO   = 4'd6,
        S_ADJOINT_WAIT = 4'd7,
        S_GRAD_READ    = 4'd8,
        S_GRAD_CAPTURE = 4'd9,
        S_GRAD_WRITE   = 4'd10,
        S_FINISH       = 4'd11;

    reg [3:0] state;
    reg [11:0] scan_addr;
    reg [10:0] meas_pos;  // Count through exactly 1024 measured coefficients.
    reg signed [31:0] residual_hold;
    reg signed [15:0] result_hold;

    assign ready = (state == S_IDLE);
    assign busy  = (state != S_IDLE);

    // Fixed 25% low-sequency mask, supplied by Stage-0.2 golden model.
    // The ROM must be initialized during simulation AND synthesis.
    (* rom_style = "distributed" *) reg mask_rom [0:4095];
    initial $readmemh("mask_4096_rowmajor.mem", mask_rom);
    wire selected = mask_rom[scan_addr];

    // Reuse the untouched Stage-2A FWHT adapter (and Stage-4 core).
    wire core_ready;
    wire core_done;
    wire signed [31:0] core_raw;
    wire signed [31:0] core_norm;
    wire core_start = (state == S_FORWARD_GO) || (state == S_ADJOINT_GO);
    wire load_image = ready && load_we && !load_kind;
    wire core_we = load_image || (state == S_RES_WRITE);
    wire [11:0] core_addr = ready ? load_addr : scan_addr;
    wire signed [31:0] core_wdata =
        (state == S_RES_WRITE) ? residual_hold :
        $signed({{16{load_data[15]}}, load_data[15:0]});

    fwht_q11_stage2 u_fwht (
        .clk(clk), .rst_n(rst_n), .start(core_start),
        .ready(core_ready), .done(core_done),
        .ext_we(core_we), .ext_addr(core_addr),
        .ext_wdata_s32(core_wdata),
        .ext_rdata_raw_s32(core_raw),
        .ext_rdata_norm_s32(core_norm)
    );

    // Preserve original input image z while the FWHT RAM is overwritten.
    (* ram_style = "block" *) reg signed [15:0] z_mem [0:4095];
    reg signed [15:0] z_rdata;
    always @(posedge clk) begin
        if (load_image)
            z_mem[load_addr] <= load_data[15:0];
        else if (state == S_GRAD_READ)
            z_rdata <= z_mem[scan_addr];
    end

    // Rewritable measurement memory; mask remains fixed in ROM.
    wire load_meas = ready && load_we && load_kind;
    (* ram_style = "block" *) reg signed [31:0] meas_mem [0:1023];
    reg signed [31:0] meas_rdata;
    always @(posedge clk) begin
        if (load_meas)
            meas_mem[load_addr[9:0]] <= load_data;
        else if (state == S_RES_READ)
            meas_rdata <= meas_mem[meas_pos[9:0]];
    end

    // Output buffer: internal write port, independent synchronous read port.
    // No whole-array reset, so it can infer BRAM on XC7Z020.
    (* ram_style = "block" *) reg signed [15:0] result_mem [0:4095];
    always @(posedge clk) begin
        if (state == S_GRAD_WRITE)
            result_mem[scan_addr] <= result_hold;
        if (read_en)
            read_data <= result_mem[read_addr];
    end
    always @(posedge clk) begin
        if (!rst_n)
            read_valid <= 1'b0;
        else
            read_valid <= read_en;
    end

    // 33-bit intermediates expose overflow BEFORE narrowing storage widths.
    wire signed [32:0] coeff_ext = {core_norm[31],core_norm};
    wire signed [32:0] y_ext = {meas_rdata[31],meas_rdata};
    wire signed [32:0] residual_wide = coeff_ext - y_ext;

    wire signed [32:0] z_ext = {{17{z_rdata[15]}},z_rdata};
    wire signed [32:0] grad_ext = {core_norm[31],core_norm};
    wire signed [32:0] result_wide = z_ext - grad_ext;

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE;
            scan_addr <= 12'd0;
            meas_pos <= 11'd0;
            residual_hold <= 32'sd0;
            result_hold <= 16'sd0;
            done <= 1'b0;
            range_error <= 1'b0;
        end else begin
            done <= 1'b0;
            case (state)
                S_IDLE: begin
                    if (start && !load_we && core_ready) begin
                        scan_addr <= 12'd0;
                        meas_pos <= 11'd0;
                        range_error <= 1'b0;
                        state <= S_FORWARD_GO;
                    end
                end
                S_FORWARD_GO: state <= S_FORWARD_WAIT;
                S_FORWARD_WAIT: begin
                    if (core_done) begin
                        scan_addr <= 12'd0;
                        meas_pos <= 11'd0;
                        state <= S_RES_READ;
                    end
                end
                // One synchronous BRAM read of raw FWHT coefficient and y.
                S_RES_READ: state <= S_RES_CAPTURE;
                S_RES_CAPTURE: begin
                    if (selected) begin
                        residual_hold <= residual_wide[31:0];
                        if (residual_wide[32] != residual_wide[31])
                            range_error <= 1'b1;
                    end else
                        residual_hold <= 32'sd0;
                    state <= S_RES_WRITE;
                end
                S_RES_WRITE: begin
                    if (selected)
                        meas_pos <= meas_pos + 11'd1;
                    if (scan_addr == 12'd4095) begin
                        scan_addr <= 12'd0;
                        state <= S_ADJOINT_GO;
                    end else begin
                        scan_addr <= scan_addr + 12'd1;
                        state <= S_RES_READ;
                    end
                end
                S_ADJOINT_GO: state <= S_ADJOINT_WAIT;
                S_ADJOINT_WAIT: begin
                    if (core_done) begin
                        scan_addr <= 12'd0;
                        state <= S_GRAD_READ;
                    end
                end
                // Synchronous FWHT and original image reads.
                S_GRAD_READ: state <= S_GRAD_CAPTURE;
                S_GRAD_CAPTURE: begin
                    result_hold <= result_wide[15:0];
                    if (result_wide > 33'sd32767 ||
                        result_wide < -33'sd32768)
                        range_error <= 1'b1;
                    state <= S_GRAD_WRITE;
                end
                S_GRAD_WRITE: begin
                    if (scan_addr == 12'd4095) begin
                        scan_addr <= 12'd0;
                        state <= S_FINISH;
                    end else begin
                        scan_addr <= scan_addr + 12'd1;
                        state <= S_GRAD_READ;
                    end
                end
                S_FINISH: begin
                    done <= 1'b1;
                    state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
