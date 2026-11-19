`timescale 1ns / 1ps
// Stage 4 synthesis-fix version: BRAM-friendly, single-port in-place FWHT.
// Purpose: signed integer FWHT (NOT full image system, TV-FISTA, or FPGA board demo).
// Interface matches the original tb_fwht_inplace.v without modification.
// Memory policy: one synchronous read OR one synchronous write per clock.
// Each butterfly is performed with 2 read clocks followed by 2 write clocks.
module fwht_inplace #(
    parameter integer LOG2_POINTS = 12,
    parameter integer POINTS = (1 << LOG2_POINTS),
    parameter integer DATA_WIDTH = 32
)(
    input  wire                           clk,
    input  wire                           rst_n,
    input  wire                           start,
    output wire                           ready,
    output reg                            done,
    input  wire                           ext_we,
    input  wire [LOG2_POINTS-1:0]         ext_addr,
    input  wire signed [DATA_WIDTH-1:0]   ext_wdata,
    output wire signed [DATA_WIDTH-1:0]   ext_rdata
);
    localparam [2:0]
        ST_IDLE    = 3'd0,
        ST_READ_A  = 3'd1,
        ST_READ_B  = 3'd2,
        ST_WRITE_A = 3'd3,
        ST_WRITE_B = 3'd4,
        ST_DONE    = 3'd5;

    reg [2:0] state;
    reg [4:0] stage;
    reg [LOG2_POINTS-1:0] pair_index;
    reg signed [DATA_WIDTH-1:0] a_reg, b_reg;

    // Butterfly addresses differ at bit 'stage'. The sequential RAM port
    // accesses these addresses in separate cycles; no multiport inference.
    wire [LOG2_POINTS-1:0] half =
        ({{(LOG2_POINTS-1){1'b0}}, 1'b1} << stage);
    wire [LOG2_POINTS-1:0] low_mask =
        half - {{(LOG2_POINTS-1){1'b0}}, 1'b1};
    wire [LOG2_POINTS-1:0] index_a =
        ((pair_index >> stage) << (stage + 5'd1)) |
        (pair_index & low_mask);
    wire [LOG2_POINTS-1:0] index_b = index_a | half;

    reg [LOG2_POINTS-1:0] ram_addr;
    reg                      ram_we;
    reg signed [DATA_WIDTH-1:0] ram_wdata;
    reg signed [DATA_WIDTH-1:0] ram_rdata;

    // One memory array, exactly one physical address port.
    (* ram_style = "block" *) reg signed [DATA_WIDTH-1:0] mem [0:POINTS-1];

    // Standard synchronous single-port RAM, no-change write mode.
    // RAM and ram_rdata are intentionally NOT reset.
    always @(posedge clk) begin
        if (ram_we)
            mem[ram_addr] <= ram_wdata;
        else
            ram_rdata <= mem[ram_addr];
    end

    // Combinational muxes drive the single RAM port.
    always @* begin
        ram_addr = ext_addr;
        ram_we = 1'b0;
        ram_wdata = {DATA_WIDTH{1'b0}};
        case (state)
            ST_IDLE: begin
                ram_addr = ext_addr;
                ram_we = ext_we;
                ram_wdata = ext_wdata;
            end
            ST_READ_A:  ram_addr = index_a;
            ST_READ_B:  ram_addr = index_b;
            ST_WRITE_A: begin
                ram_addr = index_a;
                ram_we = 1'b1;
                ram_wdata = a_reg + ram_rdata;
            end
            ST_WRITE_B: begin
                ram_addr = index_b;
                ram_we = 1'b1;
                ram_wdata = a_reg - b_reg;
            end
            default: begin
                ram_addr = ext_addr;
            end
        endcase
    end

    assign ready = (state == ST_IDLE);
    assign ext_rdata = ram_rdata;  // 1-clock synchronous read in IDLE.

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            done <= 1'b0;
            stage <= 5'd0;
            pair_index <= {LOG2_POINTS{1'b0}};
            a_reg <= {DATA_WIDTH{1'b0}};
            b_reg <= {DATA_WIDTH{1'b0}};
        end else begin
            done <= 1'b0;
            case (state)
                ST_IDLE: begin
                    if (start && !ext_we) begin
                        stage <= 5'd0;
                        pair_index <= {LOG2_POINTS{1'b0}};
                        state <= ST_READ_A;
                    end
                end
                ST_READ_A: begin
                    // At this rising edge RAM reads A into ram_rdata.
                    state <= ST_READ_B;
                end
                ST_READ_B: begin
                    // Capture A while RAM fetches B into ram_rdata.
                    a_reg <= ram_rdata;
                    state <= ST_WRITE_A;
                end
                ST_WRITE_A: begin
                    // Write A+B; capture B for use in the following cycle.
                    b_reg <= ram_rdata;
                    state <= ST_WRITE_B;
                end
                ST_WRITE_B: begin
                    // Write A-B and advance to the next butterfly.
                    if (pair_index == (POINTS/2 - 1)) begin
                        pair_index <= {LOG2_POINTS{1'b0}};
                        if (stage == LOG2_POINTS - 1)
                            state <= ST_DONE;
                        else begin
                            stage <= stage + 5'd1;
                            state <= ST_READ_A;
                        end
                    end else begin
                        pair_index <= pair_index + {{(LOG2_POINTS-1){1'b0}}, 1'b1};
                        state <= ST_READ_A;
                    end
                end
                ST_DONE: begin
                    done <= 1'b1;
                    state <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
