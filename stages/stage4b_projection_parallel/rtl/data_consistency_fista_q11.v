`timescale 1ns / 1ps
// Stage-3 FISTA data-consistency engine.
// Extends the frozen Stage-2B engine with an exact W^T*y initialization mode.
// The same 4096-point FWHT core is reused for initialization, forward transform,
// and adjoint transform. Stage-2B original RTL remains unchanged.
//
// Numeric contract (Stage-0.2):
//   image/state: signed Q5.11 (16-bit)
//   FWHT, measurement, residual: signed S32.F11
//   W = H_4096 / 64; normalize only after complete transform using >>> 6
//   measurement vector packed in ascending mask-index order (1024 entries)
//
// Load protocol while ready:
//   load_kind=1: packed measurement y[0..1023], signed S32.F11
//   load_kind=0: current extrapolated image z[0..4095], signed Q5.11
// Operations:
//   init_start: create [y at mask positions, zero elsewhere], run H/64, store W^T*y
//   start:      v = z - W^T P_Omega^T(P_Omega Wz - y)
// Output result read is synchronous (read_valid one cycle after read_en).
module data_consistency_fista_q11 (
    input wire clk,
    input wire rst_n,
    input wire start,
    input wire init_start,
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
    localparam [4:0]
        S_IDLE               = 5'd0,
        S_FORWARD_GO         = 5'd1,
        S_FORWARD_WAIT       = 5'd2,
        S_RES_READ           = 5'd3,
        S_RES_CAPTURE        = 5'd4,
        S_RES_WRITE          = 5'd5,
        S_ADJOINT_GO         = 5'd6,
        S_ADJOINT_WAIT       = 5'd7,
        S_GRAD_READ          = 5'd8,
        S_GRAD_CAPTURE       = 5'd9,
        S_GRAD_WRITE         = 5'd10,
        S_INIT_READ          = 5'd11,
        S_INIT_CAPTURE       = 5'd12,
        S_INIT_WRITE         = 5'd13,
        S_INIT_GO            = 5'd14,
        S_INIT_WAIT          = 5'd15,
        S_INIT_RESULT_READ   = 5'd16,
        S_INIT_RESULT_CAPTURE= 5'd17,
        S_INIT_RESULT_WRITE  = 5'd18,
        S_FINISH             = 5'd19;

    reg [4:0] state;
    reg [11:0] scan_addr;
    reg [10:0] meas_pos;
    reg signed [31:0] residual_hold;
    reg signed [31:0] init_hold;
    reg signed [15:0] result_hold;

    assign ready = (state == S_IDLE);
    assign busy  = (state != S_IDLE);

    (* rom_style = "distributed" *) reg mask_rom [0:4095];
    initial $readmemh("mask_4096_rowmajor.mem", mask_rom);
    wire selected = mask_rom[scan_addr];

    wire core_ready;
    wire core_done;
    wire signed [31:0] core_raw;
    wire signed [31:0] core_norm;
    wire core_start = (state == S_FORWARD_GO) ||
                      (state == S_ADJOINT_GO) ||
                      (state == S_INIT_GO);
    wire load_image = ready && load_we && !load_kind;
    wire load_meas  = ready && load_we && load_kind;
    wire core_we = load_image || (state == S_RES_WRITE) || (state == S_INIT_WRITE);
    wire [11:0] core_addr = ready ? load_addr : scan_addr;
    wire signed [31:0] core_wdata =
        (state == S_INIT_WRITE) ? init_hold :
        (state == S_RES_WRITE)  ? residual_hold :
        $signed({{16{load_data[15]}}, load_data[15:0]});

    fwht_q11_stage2 u_fwht (
        .clk(clk), .rst_n(rst_n), .start(core_start),
        .ready(core_ready), .done(core_done),
        .ext_we(core_we), .ext_addr(core_addr),
        .ext_wdata_s32(core_wdata),
        .ext_rdata_raw_s32(core_raw),
        .ext_rdata_norm_s32(core_norm)
    );

    (* ram_style = "block" *) reg signed [15:0] z_mem [0:4095];
    reg signed [15:0] z_rdata;
    always @(posedge clk) begin
        if (load_image)
            z_mem[load_addr] <= load_data[15:0];
        else if (state == S_GRAD_READ)
            z_rdata <= z_mem[scan_addr];
    end

    (* ram_style = "block" *) reg signed [31:0] meas_mem [0:1023];
    reg signed [31:0] meas_rdata;
    always @(posedge clk) begin
        if (load_meas)
            meas_mem[load_addr[9:0]] <= load_data;
        else if ((state == S_RES_READ) || (state == S_INIT_READ))
            meas_rdata <= meas_mem[meas_pos[9:0]];
    end

    (* ram_style = "block" *) reg signed [15:0] result_mem [0:4095];
    always @(posedge clk) begin
        if ((state == S_GRAD_WRITE) || (state == S_INIT_RESULT_WRITE))
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

    wire signed [32:0] coeff_ext = {core_norm[31], core_norm};
    wire signed [32:0] y_ext = {meas_rdata[31], meas_rdata};
    wire signed [32:0] residual_wide = coeff_ext - y_ext;
    wire signed [32:0] z_ext = {{17{z_rdata[15]}}, z_rdata};
    wire signed [32:0] grad_ext = {core_norm[31], core_norm};
    wire signed [32:0] result_wide = z_ext - grad_ext;
    wire signed [32:0] init_result_wide = {core_norm[31], core_norm};

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE;
            scan_addr <= 12'd0;
            meas_pos <= 11'd0;
            residual_hold <= 32'sd0;
            init_hold <= 32'sd0;
            result_hold <= 16'sd0;
            done <= 1'b0;
            range_error <= 1'b0;
        end else begin
            done <= 1'b0;
            case (state)
                S_IDLE: begin
                    if (init_start && !start && !load_we && core_ready) begin
                        scan_addr <= 12'd0;
                        meas_pos <= 11'd0;
                        range_error <= 1'b0;
                        state <= S_INIT_READ;
                    end else if (start && !init_start && !load_we && core_ready) begin
                        scan_addr <= 12'd0;
                        meas_pos <= 11'd0;
                        range_error <= 1'b0;
                        state <= S_FORWARD_GO;
                    end
                end

                // Exact initialization: load the packed y values into their
                // selected positions and zeros into all unmeasured positions.
                S_INIT_READ: state <= S_INIT_CAPTURE;
                S_INIT_CAPTURE: begin
                    if (selected)
                        init_hold <= meas_rdata;
                    else
                        init_hold <= 32'sd0;
                    state <= S_INIT_WRITE;
                end
                S_INIT_WRITE: begin
                    if (selected)
                        meas_pos <= meas_pos + 11'd1;
                    if (scan_addr == 12'd4095) begin
                        scan_addr <= 12'd0;
                        state <= S_INIT_GO;
                    end else begin
                        scan_addr <= scan_addr + 12'd1;
                        state <= S_INIT_READ;
                    end
                end
                S_INIT_GO: state <= S_INIT_WAIT;
                S_INIT_WAIT: begin
                    if (core_done) begin
                        scan_addr <= 12'd0;
                        state <= S_INIT_RESULT_READ;
                    end
                end
                S_INIT_RESULT_READ: state <= S_INIT_RESULT_CAPTURE;
                S_INIT_RESULT_CAPTURE: begin
                    result_hold <= core_norm[15:0];
                    if (init_result_wide > 33'sd32767 ||
                        init_result_wide < -33'sd32768)
                        range_error <= 1'b1;
                    state <= S_INIT_RESULT_WRITE;
                end
                S_INIT_RESULT_WRITE: begin
                    if (scan_addr == 12'd4095) begin
                        scan_addr <= 12'd0;
                        state <= S_FINISH;
                    end else begin
                        scan_addr <= scan_addr + 12'd1;
                        state <= S_INIT_RESULT_READ;
                    end
                end

                // Normal Stage-2B data-consistency gradient step.
                S_FORWARD_GO: state <= S_FORWARD_WAIT;
                S_FORWARD_WAIT: begin
                    if (core_done) begin
                        scan_addr <= 12'd0;
                        meas_pos <= 11'd0;
                        state <= S_RES_READ;
                    end
                end
                S_RES_READ: state <= S_RES_CAPTURE;
                S_RES_CAPTURE: begin
                    if (selected) begin
                        residual_hold <= residual_wide[31:0];
                        if (residual_wide[32] != residual_wide[31])
                            range_error <= 1'b1;
                    end else begin
                        residual_hold <= 32'sd0;
                    end
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
