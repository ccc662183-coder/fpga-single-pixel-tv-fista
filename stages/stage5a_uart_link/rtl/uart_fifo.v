`timescale 1ns / 1ps
// Reconstructed BRAM-inference candidate, NOT the user's original timing-PASS RTL.
// Vivado 2019.2, FPGA AX7020, FIFO ready/valid, DEPTH=2**ADDR_W.
// Core trick: a dedicated, unreset RAM read-data register plus a separate
// input-to-head bypass register. These are selected after the clock edge.
// This code has NOT been verified by Vivado synthesis or XSim.
module uart_fifo #(
    parameter integer ADDR_W = 12
)(
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire [7:0]           in_data,
    input  wire                 in_valid,
    output wire                 in_ready,
    output wire [7:0]           out_data,
    output reg                  out_valid,
    input  wire                 out_ready,
    output wire [ADDR_W:0]      level,
    output wire                 full,
    output wire                 empty
);
    localparam integer DEPTH = (1 << ADDR_W);
    localparam [ADDR_W:0] DEPTH_W = DEPTH;

    (* ram_style = "block" *) reg [7:0] ram [0:DEPTH-1];
    reg [ADDR_W-1:0] wr_ptr;
    reg [ADDR_W-1:0] rd_ptr;
    reg [ADDR_W:0] ram_count;

    // The RAM's synchronous read register cannot be asynchronously reset.
    reg [7:0] ram_rd_data;
    reg [7:0] bypass_data;
    reg       head_from_ram;

    assign out_data = head_from_ram ? ram_rd_data : bypass_data;
    assign level = ram_count + {{ADDR_W{1'b0}}, out_valid};
    assign full = (level == DEPTH_W);
    assign empty = (level == { (ADDR_W+1){1'b0} });

    wire pop = out_valid && out_ready;
    assign in_ready = rst_n && (!full || pop);
    wire push = in_valid && in_ready;
    wire advance_head = !out_valid || pop;
    wire ram_to_head = advance_head && (ram_count != 0);
    wire input_to_head = advance_head && (ram_count == 0) && push;
    wire input_to_ram = push && !input_to_head;

    // Addresses feeding BRAM have only *synchronous* reset.
    // rst_n is assumed low for >=1 active clk edge when link_flush occurs.
    always @(posedge clk) begin
        if (!rst_n) begin
            wr_ptr <= {ADDR_W{1'b0}};
            rd_ptr <= {ADDR_W{1'b0}};
        end else begin
            if (input_to_ram) wr_ptr <= wr_ptr + 1'b1;
            if (ram_to_head)  rd_ptr <= rd_ptr + 1'b1;
        end
    end

    // Standard simple-dual-port BRAM write: no asynchronous reset.
    always @(posedge clk) begin
        if (rst_n && input_to_ram)
            ram[wr_ptr] <= in_data;
    end

    // Standard synchronous BRAM read. ram_rd_data has no reset, bypass,
    // additional data processing or non-BRAM assignments.
    always @(posedge clk) begin
        if (rst_n && ram_to_head)
            ram_rd_data <= ram[rd_ptr];
    end

    // Bypass path serves the very first word and gapless pop+push.
    always @(posedge clk) begin
        if (rst_n && input_to_head)
            bypass_data <= in_data;
    end

    // Validity, source selection and count reset asynchronously to support
    // the existing F08 test and the protocol link_flush behavior.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ram_count     <= {(ADDR_W+1){1'b0}};
            out_valid     <= 1'b0;
            head_from_ram <= 1'b0;
        end else begin
            if (ram_to_head)
                head_from_ram <= 1'b1;
            else if (input_to_head)
                head_from_ram <= 1'b0;

            if (advance_head)
                out_valid <= ram_to_head || input_to_head;

            case ({input_to_ram, ram_to_head})
                2'b10: ram_count <= ram_count + 1'b1;
                2'b01: ram_count <= ram_count - 1'b1;
                default: ;
            endcase
        end
    end
endmodule
