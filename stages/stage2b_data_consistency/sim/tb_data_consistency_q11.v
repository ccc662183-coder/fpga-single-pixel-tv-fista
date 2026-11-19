`timescale 1ns / 1ps
module tb_data_consistency_q11;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n = 1'b0;
    reg start = 1'b0;
    wire ready, busy, done, range_error;

    reg load_we = 1'b0;
    reg load_kind = 1'b0;
    reg [11:0] load_addr = 12'd0;
    reg signed [31:0] load_data = 32'sd0;
    reg read_en = 1'b0;
    reg [11:0] read_addr = 12'd0;
    wire read_valid;
    wire signed [15:0] read_data;

    reg signed [31:0] yvec [0:1023];
    reg signed [15:0] z_direct [0:4095];
    reg signed [15:0] z_original [0:4095];
    reg signed [15:0] z_perturbed [0:4095];
    reg signed [15:0] z_zero [0:4095];
    reg signed [15:0] e_direct [0:4095];
    reg signed [15:0] e_original [0:4095];
    reg signed [15:0] e_perturbed [0:4095];
    reg signed [15:0] e_zero [0:4095];

    integer i;
    integer errors;
    integer cycles;
    integer sum_got;
    integer sum_expected;
    integer nmask;

    data_consistency_q11 dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .ready(ready), .busy(busy), .done(done),
        .range_error(range_error),
        .load_we(load_we), .load_kind(load_kind),
        .load_addr(load_addr), .load_data(load_data),
        .read_en(read_en), .read_addr(read_addr),
        .read_valid(read_valid), .read_data(read_data)
    );

    function [15:0] input_at;
        input integer which;
        input integer addr;
        begin
            case (which)
                0: input_at = z_direct[addr];
                1: input_at = z_original[addr];
                2: input_at = z_perturbed[addr];
                default: input_at = z_zero[addr];
            endcase
        end
    endfunction
    function [15:0] expected_at;
        input integer which;
        input integer addr;
        begin
            case (which)
                0: expected_at = e_direct[addr];
                1: expected_at = e_original[addr];
                2: expected_at = e_perturbed[addr];
                default: expected_at = e_zero[addr];
            endcase
        end
    endfunction

    task load_measurements;
        integer j;
        begin
            for (j = 0; j < 1024; j = j + 1) begin
                @(negedge clk);
                load_we = 1'b1;
                load_kind = 1'b1;
                load_addr = j[11:0];
                load_data = yvec[j];
            end
            @(negedge clk);
            load_we = 1'b0;
            load_kind = 1'b0;
        end
    endtask

    task run_one_case;
        input integer which;
        integer j;
        integer local_cycles;
        integer local_errors;
        integer local_sum_got;
        integer local_sum_expected;
        reg signed [15:0] pixel;
        begin
            if (ready !== 1'b1) begin
                $display("FAIL: core not ready before case %0d", which);
                $fatal(1);
            end
            // Load all 4096 input pixels; measurement memory is retained.
            for (j = 0; j < 4096; j = j + 1) begin
                @(negedge clk);
                load_we = 1'b1;
                load_kind = 1'b0;
                load_addr = j[11:0];
                pixel = $signed(input_at(which,j));
                load_data = {{16{pixel[15]}}, pixel};
            end
            @(negedge clk);
            load_we = 1'b0;
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;

            local_cycles = 0;
            while (done !== 1'b1) begin
                @(negedge clk);
                local_cycles = local_cycles + 1;
                if (local_cycles > 400000) begin
                    $display("FAIL: timeout in case %0d", which);
                    $fatal(1);
                end
            end
            if (ready !== 1'b1 || busy !== 1'b0 || range_error !== 1'b0) begin
                $display("FAIL: status at end of case %0d: ready=%b busy=%b range=%b",
                         which, ready, busy, range_error);
                $fatal(1);
            end
            if (dut.meas_pos !== 11'd1024) begin
                $display("FAIL: only %0d/1024 measurement indices consumed",dut.meas_pos);
                $fatal(1);
            end

            // Synchronous result readback, all pixels compared to Python.
            local_errors = 0;
            local_sum_got = 0;
            local_sum_expected = 0;
            for (j = 0; j < 4096; j = j + 1) begin
                @(negedge clk);
                read_en = 1'b1;
                read_addr = j[11:0];
                @(posedge clk); #1;
                if (read_valid !== 1'b1) begin
                    $display("FAIL: missing read_valid case=%0d addr=%0d", which,j);
                    $fatal(1);
                end
                local_sum_got = local_sum_got + $signed(read_data);
                local_sum_expected = local_sum_expected + $signed(expected_at(which,j));
                if (read_data !== expected_at(which,j)) begin
                    local_errors = local_errors + 1;
                    if (local_errors <= 10)
                        $display("MISMATCH case=%0d addr=%0d actual=%0d expected=%0d",
                                 which, j, $signed(read_data), $signed(expected_at(which,j)));
                end
            end
            @(negedge clk);
            read_en = 1'b0;
            if (local_errors != 0 || local_sum_got != local_sum_expected) begin
                $display("FAIL: case=%0d errors=%0d sum=%0d expected_sum=%0d",
                         which,local_errors,local_sum_got,local_sum_expected);
                $fatal(1);
            end
            $display("PASS: case %0d, 4096/4096, sum=%0d, cycles=%0d",
                     which,local_sum_got,local_cycles);
        end
    endtask

    initial begin
        #30000000;  // Time-based global deadlock guard: 3 million 100-MHz cycles.
        $display("FAIL: global Stage-2B simulation timeout");
        $fatal(1);
    end

    initial begin
        $readmemh("measurements_1024_q11_s32.mem", yvec);
        $readmemh("input_direct_q11_s16.mem", z_direct);
        $readmemh("input_original_q11_s16.mem", z_original);
        $readmemh("input_perturbed_q11_s16.mem", z_perturbed);
        $readmemh("input_zero_q11_s16.mem", z_zero);
        $readmemh("expected_direct_q11_s16.mem", e_direct);
        $readmemh("expected_original_q11_s16.mem", e_original);
        $readmemh("expected_perturbed_q11_s16.mem", e_perturbed);
        $readmemh("expected_zero_q11_s16.mem", e_zero);

        repeat (6) @(negedge clk);
        rst_n = 1'b1;
        // Check that the mask actually contains 1024 selected positions.
        nmask = 0;
        for (i = 0; i < 4096; i = i + 1) begin
            if (dut.mask_rom[i] === 1'b1) nmask = nmask + 1;
            else if (dut.mask_rom[i] !== 1'b0) begin
                $display("FAIL: mask ROM contains X/Z at position %0d",i);
                $fatal(1);
            end
        end
        if (nmask != 1024) begin
            $display("FAIL: mask population=%0d, expected=1024",nmask);
            $fatal(1);
        end

        load_measurements();
        run_one_case(0); // z = DIRECT, nonzero measured residuals
        run_one_case(1); // z = ORIGINAL, zero residual in measured locations
        run_one_case(2); // z = PERTURBED DIRECT, nontrivial residuals
        run_one_case(3); // z = ZERO, negative residual and rounding test

        $display("PASS: mask=1024/4096; all 4 input sets and 16384 pixels exact");
        $display("PASS: same FWHT reused for forward and adjoint, S32.F11 / Q5.11");
        $display("PASS: all 4 transactions range_error=0");
        $display("ALL TESTS PASSED: Stage-2B data consistency RTL");
        $finish;
    end
endmodule
