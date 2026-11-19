`timescale 1ns / 1ps
// AX7020 Stage-5A communication bring-up. Frozen Stage-4C compute core NOT modified.
// Single 50MHz PL clock domain for UART/control; no Clock Wizard needed here.
// All packet logic below is reused from the user's previously verified UART experiment.
module stage5a_uart_link_top (
    input  wire clk_50m,   // AX7020 PL clock: U18, 50MHz
    input  wire rst_n,     // AX7020 PL KEY1: N15, active low
    input  wire uart_rx_i, // J10 PIN3, W19, from nanoDAP U_TX
    output wire uart_tx_o  // J10 PIN4, W18, to nanoDAP U_RX
);
    // Reset assert asynchronous, release synchronous to the 50MHz PL clock.
    reg [2:0] reset_sync = 3'b000;
    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) reset_sync <= 3'b000;
        else        reset_sync <= {reset_sync[1:0], 1'b1};
    end
    wire link_rst_n = reset_sync[2];

    wire [26:0] active_baud;
    wire switch_pending, baud_changed, rollback_pulse;
    wire [12:0] rx_fifo_level;
    wire [31:0] rx_fifo_drop_count;
    wire [31:0] crc_error_count, format_error_count, timeout_count;

    uart_protocol_core #(
        .CLK_HZ(50_000_000),
        .FIFO_ADDR_W(12),
        .DEFAULT_BAUD(27'd1000000),
        .GUARD_CYCLES(100000),       // 2ms at 50MHz (original: 400000 at 200MHz)
        .DRAIN_TIMEOUT_CYCLES(5000000),
        .PREP_TIMEOUT_CYCLES(100000000),
        .CONFIRM_TIMEOUT_CYCLES(100000000),
        .RESP_TIMEOUT_CYCLES(100000000)
    ) u_protocol_core (
        .clk(clk_50m), .rst_n(link_rst_n),
        .uart_rx_i(uart_rx_i), .uart_tx_o(uart_tx_o),
        .active_baud(active_baud),
        .switch_pending(switch_pending),
        .baud_changed(baud_changed),
        .rollback_pulse(rollback_pulse),
        .rx_fifo_level(rx_fifo_level),
        .rx_fifo_drop_count(rx_fifo_drop_count),
        .crc_error_count(crc_error_count),
        .format_error_count(format_error_count),
        .timeout_count(timeout_count)
    );
endmodule
