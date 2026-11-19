`timescale 1ns / 1ps

// End-to-end UART protocol test. Serial bitstream is driven and decoded
// independently of the FPGA packet TX/RX implementations.
module tb_stage5a_uart_link;
    localparam integer CLK_HZ = 50_000_000;
    localparam integer CONFIRM_TICKS = 80_000; // 0.4 ms only in this TB

    reg clk = 1'b0;
    always #10 clk = ~clk;
    reg rst_n = 1'b0;
    reg uart_rx_i = 1'b1;
    wire uart_tx_o;
    wire [26:0] active_baud;
    wire switch_pending, baud_changed, rollback_pulse;
    wire [4:0] rx_fifo_level;
    wire [31:0] rx_fifo_drop_count;
    wire [31:0] crc_error_count, format_error_count, timeout_count;

    stage5a_uart_link_top dut (
        .clk_50m(clk), .rst_n(rst_n),
        .uart_rx_i(uart_rx_i), .uart_tx_o(uart_tx_o)
    );
    // Debug signals accessible through DUT instance in simulation only.
    assign active_baud = dut.u_protocol_core.active_baud;
    assign switch_pending = dut.u_protocol_core.switch_pending;
    assign baud_changed = dut.u_protocol_core.baud_changed;
    assign rollback_pulse = dut.u_protocol_core.rollback_pulse;
    assign rx_fifo_level = dut.u_protocol_core.rx_fifo_level[4:0];
    assign rx_fifo_drop_count = dut.u_protocol_core.rx_fifo_drop_count;
    assign crc_error_count = dut.u_protocol_core.crc_error_count;
    assign format_error_count = dut.u_protocol_core.format_error_count;
    assign timeout_count = dut.u_protocol_core.timeout_count;

    integer pc_bit_ns = 1000;  // PC side changes independently of FPGA
    reg [7:0] payload [0:255];
    reg [7:0] expected_payload [0:255];
    reg [7:0] wire_rx [0:4095];
    integer rx_count = 0;
    integer consumed = 0;
    integer mon_ns;
    integer mon_bit;
    reg [7:0] mon_byte;
    integer j;
    integer waits;
    reg [15:0] crc;
    reg [15:0] rx_crc;

    // Monitor actual FPGA UART output at each nominal bit center.
    always @(negedge uart_tx_o) begin
        if (rst_n) begin
            mon_ns = pc_bit_ns;
            #(mon_ns / 2);
            if (uart_tx_o !== 1'b0)
                $fatal(1, "[FAIL] TX start bit invalid");
            for (mon_bit = 0; mon_bit < 8; mon_bit = mon_bit + 1) begin
                #(mon_ns);
                mon_byte[mon_bit] = uart_tx_o;
            end
            #(mon_ns);
            if (uart_tx_o !== 1'b1)
                $fatal(1, "[FAIL] TX stop bit invalid at byte %0d", rx_count);
            if (rx_count >= 4096)
                $fatal(1, "[FAIL] testbench receive overflow");
            wire_rx[rx_count] = mon_byte;
            rx_count = rx_count + 1;
        end
    end

    function [15:0] crc_next;
        input [15:0] old_crc;
        input [7:0] b;
        reg [15:0] work;
        integer k;
        begin
            work = old_crc;
            for (k = 7; k >= 0; k = k - 1) begin
                if (work[15] ^ b[k])
                    work = {work[14:0], 1'b0} ^ 16'h1021;
                else
                    work = {work[14:0], 1'b0};
            end
            crc_next = work;
        end
    endfunction

    task uart_send_byte;
        input [7:0] data;
        integer bitno;
        begin
            @(negedge clk);
            uart_rx_i = 1'b0;
            #(pc_bit_ns);
            for (bitno = 0; bitno < 8; bitno = bitno + 1) begin
                uart_rx_i = data[bitno];
                #(pc_bit_ns);
            end
            uart_rx_i = 1'b1;
            #(pc_bit_ns);
        end
    endtask

    task send_packet;
        input [7:0] typ;
        input [15:0] seq;
        input integer len;
        input integer corrupt_crc;
        integer k;
        reg [15:0] value;
        begin
            value = 16'hFFFF;
            uart_send_byte(8'hA5);
            uart_send_byte(8'h5A);
            uart_send_byte(8'h01); value = crc_next(value, 8'h01);
            uart_send_byte(typ);   value = crc_next(value, typ);
            uart_send_byte(seq[7:0]); value = crc_next(value, seq[7:0]);
            uart_send_byte(seq[15:8]); value = crc_next(value, seq[15:8]);
            uart_send_byte(len & 8'hFF); value = crc_next(value, len & 8'hFF);
            uart_send_byte((len >> 8) & 8'hFF);
            value = crc_next(value, (len >> 8) & 8'hFF);
            for (k = 0; k < len; k = k + 1) begin
                uart_send_byte(payload[k]);
                value = crc_next(value, payload[k]);
            end
            if (corrupt_crc != 0)
                value = value ^ 16'h0001;
            uart_send_byte(value[7:0]);
            uart_send_byte(value[15:8]);
        end
    endtask

    task expected_u32;
        input [31:0] v;
        begin
            expected_payload[0] = v[7:0];
            expected_payload[1] = v[15:8];
            expected_payload[2] = v[23:16];
            expected_payload[3] = v[31:24];
        end
    endtask

    task request_u32;
        input [31:0] v;
        begin
            payload[0] = v[7:0];
            payload[1] = v[15:8];
            payload[2] = v[23:16];
            payload[3] = v[31:24];
        end
    endtask

   
task expect_response;
    input [7:0] typ;
    input [15:0] seq;
    input integer len;

    integer k;
    integer offset;
    reg [15:0] calc;

    begin
        waits = 0;

        // Allow up to 3 ms at 200 MHz
        while (
            (rx_count - consumed < len + 10) &&
            (waits < 600_000)
        ) begin
            @(negedge clk);
            waits = waits + 1;
        end

        if (rx_count - consumed < len + 10)
            $fatal(1,
                "[FAIL] response timeout: type=%02h seq=%04h received=%0d",
                typ, seq, rx_count-consumed);

        offset = consumed;

        if (wire_rx[offset] !== 8'hA5 ||
            wire_rx[offset+1] !== 8'h5A ||
            wire_rx[offset+2] !== 8'h01 ||
            wire_rx[offset+3] !== typ ||
            wire_rx[offset+4] !== seq[7:0] ||
            wire_rx[offset+5] !== seq[15:8] ||
            wire_rx[offset+6] !== (len & 8'hFF) ||
            wire_rx[offset+7] !== ((len >> 8) & 8'hFF))
            $fatal(1,
                "[FAIL] response header/type/seq/length mismatch: type=%02h seq=%04h",
                typ, seq);

        calc = 16'hFFFF;

        for (k = 2; k < 8 + len; k = k + 1)
            calc = crc_next(calc, wire_rx[offset+k]);

        rx_crc = {
            wire_rx[offset+9+len],
            wire_rx[offset+8+len]
        };

        if (calc !== rx_crc)
            $fatal(1,
                "[FAIL] response CRC expected=%04h got=%04h",
                calc, rx_crc);

        for (k = 0; k < len; k = k + 1) begin
            if (wire_rx[offset+8+k] !== expected_payload[k])
                $fatal(1,
                    "[FAIL] response payload[%0d] expected=%02h got=%02h",
                    k,
                    expected_payload[k],
                    wire_rx[offset+8+k]);
        end

        consumed = consumed + len + 10;

        // Wait for final UART STOP boundary
        repeat (4) @(negedge clk);

    end
endtask


    task wait_baud;
        input [26:0] target;
        integer tries;
        begin
            tries = 0;
            while ((active_baud !== target) && tries < 150_000) begin
                @(negedge clk);
                tries = tries + 1;
            end
            if (active_baud !== target)
                $fatal(1, "[FAIL] baud never changed to %0d, currently %0d", target, active_baud);
        end
    endtask

    initial begin
        #20_000_000;
        $fatal(1, "[FAIL] Stage-5A global timeout");
    end

    initial begin
        $display("===== STAGE-5A 50MHz UART LINK TEST START =====");
        repeat (8) @(negedge clk);
        rst_n = 1'b1;
        repeat (12) @(negedge clk);
        if (active_baud !== 27'd1000000)
            $fatal(1,"[FAIL] Expected 1000000 baud, got %0d", active_baud);

        // S01: UART status response at 50MHz clock, 1Mbps line.
        send_packet(8'h10, 16'h0101, 0, 0);
        expected_u32(32'd1000000);
        expect_response(8'h11, 16'h0101, 4);
        $display("PASS: Stage-5A GET_STATUS -> 1000000 bps");

        // S02: Payload containing sync markers must remain transparent.
        payload[0] = 8'hA5; payload[1] = 8'h5A;
        payload[2] = 8'h00; payload[3] = 8'hFF;
        payload[4] = 8'h35; payload[5] = 8'h00;
        payload[6] = 8'hA5; payload[7] = 8'h5A;
        for (j=0; j<8; j=j+1) expected_payload[j]=payload[j];
        send_packet(8'h20, 16'h0102, 8, 0);
        expect_response(8'h21, 16'h0102, 8);
        $display("PASS: Stage-5A binary 8-byte echo incl A5 5A 00 FF");

        // S03: Full payload length, 256B, stop-and-wait and CRC validation.
        for (j=0; j<256; j=j+1) begin
            payload[j] = (j * 73 + 19) ^ (j >> 3);
            expected_payload[j] = payload[j];
        end
        send_packet(8'h20,16'h0103,256,0);
        expect_response(8'h21,16'h0103,256);
        $display("PASS: Stage-5A full 256-byte payload echo, CRC exact");

        // S04: Corrupted CRC must be discarded; subsequent clean link recovers.
        send_packet(8'h10, 16'h0104, 0, 1);
        repeat(100) @(negedge clk);
        send_packet(8'h10, 16'h0105, 0, 0);
        expected_u32(32'd1000000);
        expect_response(8'h11, 16'h0105, 4);
        if (crc_error_count == 0)
            $fatal(1,"[FAIL] CRC error not detected");
        if (rx_fifo_drop_count != 0)
            $fatal(1,"[FAIL] FIFO dropped bytes=%0d", rx_fifo_drop_count);
        if (consumed !== rx_count)
            $fatal(1,"[FAIL] unexpected response bytes=%0d",rx_count-consumed);
        $display("PASS: Stage-5A bad-CRC rejection and recovery");
        $display("ALL TESTS PASSED: Stage-5A AX7020 UART 50MHz link verification");
        $finish;
    end
endmodule
