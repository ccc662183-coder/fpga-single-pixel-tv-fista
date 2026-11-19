
`timescale 1ns / 1ps

// ============================================================
// Stage-3 TV-FISTA Full Testbench
// FPGA: XC7Z020
// Clock: 50 MHz
// OUTER_ITERS = 1  : Single iteration test
// OUTER_ITERS = 40 : Full FISTA reconstruction test
// ============================================================

module tb_fista_top_q11_run;

    parameter integer OUTER_ITERS = 1;

    localparam integer N = 4096;
    localparam integer M = 1024;

    // Explicitly sized timeout constants.
    // 30,000,000,000 ns = 30 seconds.
    localparam [63:0] GLOBAL_TIMEOUT_NS = 64'd30000000000;

    // Maximum compute cycles.
    localparam integer MAX_COMPUTE_CYCLES = 700000000;

    // --------------------------------------------------------
    // Clock and reset
    // --------------------------------------------------------

    reg clk = 1'b0;
    always #10 clk = ~clk;  // 50 MHz

    reg rst_n = 1'b0;

    // --------------------------------------------------------
    // Measurement loading interface
    // --------------------------------------------------------

    reg meas_load_we = 1'b0;
    reg [9:0] meas_load_addr = 10'd0;
    reg signed [31:0] meas_load_data = 32'sd0;

    wire meas_load_ready;

    // --------------------------------------------------------
    // FISTA control interface
    // --------------------------------------------------------

    reg start = 1'b0;

    wire ready;
    wire busy;
    wire done;

    wire range_error;
    wire protocol_error;

    wire [5:0] outer_iter;

    // --------------------------------------------------------
    // Result reading interface
    // --------------------------------------------------------

    reg result_read_en = 1'b0;
    reg [11:0] result_read_addr = 12'd0;

    wire result_read_valid;
    wire signed [15:0] result_read_data;

    // --------------------------------------------------------
    // Reference data
    // --------------------------------------------------------

    reg signed [31:0] measurements [0:M-1];
    reg [15:0] expected [0:N-1];

    // --------------------------------------------------------
    // Testbench variables
    // --------------------------------------------------------

    integer i;
    integer cycles;
    integer errors;

    integer sum_out;
    integer min_out;
    integer max_out;

    // Marks completion of ALL testbench checks.
    reg test_completed;

    // --------------------------------------------------------
    // DUT
    // --------------------------------------------------------

    tv_fista_top_q11 #(
        .OUTER_ITERS(OUTER_ITERS),
        .TV_INNER_STEPS(35)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),

        .meas_load_we(meas_load_we),
        .meas_load_addr(meas_load_addr),
        .meas_load_data(meas_load_data),
        .meas_load_ready(meas_load_ready),

        .start(start),
        .ready(ready),
        .busy(busy),
        .done(done),

        .range_error(range_error),
        .protocol_error(protocol_error),
        .outer_iter(outer_iter),

        .result_read_en(result_read_en),
        .result_read_addr(result_read_addr),
        .result_read_valid(result_read_valid),
        .result_read_data(result_read_data)
    );

    // ========================================================
    // GLOBAL WATCHDOG
    // ========================================================

    initial begin : GLOBAL_WATCHDOG

        test_completed = 1'b0;

        #(GLOBAL_TIMEOUT_NS);

        if (test_completed !== 1'b1) begin

            $display(
                "FAIL: Stage-3 global timeout at %0t, outer_iter=%0d",
                $time,
                outer_iter
            );

            $fatal(1);

        end

    end

    // Lightweight progress log during the long 40-iteration run.
    always @(outer_iter) begin
        if (rst_n === 1'b1 && OUTER_ITERS == 40 &&
            outer_iter > 0 && outer_iter < 40)
            $display("INFO: Stage-4A completed %0d of 40 outer iterations", outer_iter);
    end

    // ========================================================
    // MAIN TEST
    // ========================================================

    initial begin

        // ----------------------------------------------------
        // 1. Load reference data
        // ----------------------------------------------------

        $readmemh(
            "cat64_measurements_q11_s32.mem",
            measurements
        );

        if (OUTER_ITERS == 1) begin

            $readmemh(
                "cat64_expected_iter1_q11_s16.mem",
                expected
            );

        end
        else if (OUTER_ITERS == 40) begin

            $readmemh(
                "cat64_expected_final_q11_s16.mem",
                expected
            );

        end
        else begin

            $display(
                "FAIL: testbench supports OUTER_ITERS=1 or 40"
            );

            $fatal(1);

        end

        // ----------------------------------------------------
        // 2. Reset
        // ----------------------------------------------------

        repeat (8) @(negedge clk);

        rst_n = 1'b1;

        // ----------------------------------------------------
        // 3. Load all 1024 measurements
        // ----------------------------------------------------

        for (i = 0; i < M; i = i + 1) begin

            @(negedge clk);

            meas_load_we = 1'b1;
            meas_load_addr = i[9:0];
            meas_load_data = measurements[i];

        end

        @(negedge clk);

        meas_load_we = 1'b0;
        meas_load_addr = 10'd0;
        meas_load_data = 32'sd0;

        // Check loading completion.

        if (ready !== 1'b1 ||
            meas_load_ready !== 1'b0) begin

            $display(
                "FAIL: measurement loading did not complete; ready=%b load_ready=%b",
                ready,
                meas_load_ready
            );

            $fatal(1);

        end

        // ----------------------------------------------------
        // 4. Start FISTA
        // ----------------------------------------------------

        @(negedge clk);

        start = 1'b1;

        @(negedge clk);

        start = 1'b0;

        cycles = 0;

        // ----------------------------------------------------
        // 5. Wait for computation to finish
        // ----------------------------------------------------

        while ((done !== 1'b1) &&
               (range_error !== 1'b1) &&
               (protocol_error !== 1'b1)) begin

            @(negedge clk);

            cycles = cycles + 1;

            if (cycles > MAX_COMPUTE_CYCLES) begin

                $display(
                    "FAIL: Stage-3 exceeded %0d clocks",
                    MAX_COMPUTE_CYCLES
                );

                $display(
                    "Current outer_iter=%0d",
                    outer_iter
                );

                $fatal(1);

            end

        end

        // ----------------------------------------------------
        // 6. Check hardware error flags
        // ----------------------------------------------------

        if (range_error || protocol_error) begin

            $display(
                "FAIL: range_error=%b protocol_error=%b outer_iter=%0d cycles=%0d",
                range_error,
                protocol_error,
                outer_iter,
                cycles
            );

            $fatal(1);

        end

        if (done !== 1'b1) begin

            $display(
                "FAIL: Stage-3 did not assert done"
            );

            $fatal(1);

        end

        // ----------------------------------------------------
        // 7. Initialize output statistics
        // ----------------------------------------------------

        errors = 0;

        sum_out = 0;

        min_out = 32767;

        max_out = -32768;

        // ----------------------------------------------------
        // 8. Read and compare all 4096 output pixels
        // ----------------------------------------------------

        for (i = 0; i < N; i = i + 1) begin

            @(negedge clk);

            result_read_en = 1'b1;

            result_read_addr = i[11:0];

            @(posedge clk);

            #1;

            // Check read valid.

            if (result_read_valid !== 1'b1) begin

                errors = errors + 1;

                if (errors <= 10) begin

                    $display(
                        "READ_VALID ERROR at addr=%0d",
                        i
                    );

                end

            end

            // Compare exact pixel value.

            if (result_read_data !== $signed(expected[i])) begin

                errors = errors + 1;

                if (errors <= 10) begin

                    $display(
                        "PIXEL MISMATCH addr=%0d got=%0d expected=%0d",
                        i,
                        $signed(result_read_data),
                        $signed(expected[i])
                    );

                end

            end

            // Accumulate statistics.

            sum_out = sum_out + $signed(result_read_data);

            if ($signed(result_read_data) < min_out)
                min_out = $signed(result_read_data);

            if ($signed(result_read_data) > max_out)
                max_out = $signed(result_read_data);

        end

        @(negedge clk);

        result_read_en = 1'b0;

        // ----------------------------------------------------
        // 9. Check pixel comparison
        // ----------------------------------------------------

        if (errors != 0) begin

            $display(
                "FAIL: total read/pixel errors=%0d",
                errors
            );

            $fatal(1);

        end

        // ----------------------------------------------------
        // 10. Check golden summary
        // ----------------------------------------------------

        if (OUTER_ITERS == 1) begin

            if (sum_out != 3930561 ||
                min_out != 108 ||
                max_out != 1530) begin

                $display(
                    "FAIL: iter1 summary sum=%0d range=[%0d,%0d]",
                    sum_out,
                    min_out,
                    max_out
                );

                $fatal(1);

            end

            $display(
                "PASS: exact initial backprojection W^T*y and one FISTA iteration"
            );

        end
        else begin

            if (sum_out != 3930589 ||
                min_out != 81 ||
                max_out != 1526) begin

                $display(
                    "FAIL: final summary sum=%0d range=[%0d,%0d]",
                    sum_out,
                    min_out,
                    max_out
                );

                $fatal(1);

            end

            $display(
                "PASS: exact 40-iteration TV-FISTA final reconstruction"
            );

        end

        // ----------------------------------------------------
        // 11. Final PASS reports
        // ----------------------------------------------------


        // Stage-4A acceptance: identical golden pixels AND fewer compute cycles
        // than the frozen Stage-3 implementation.
        if ((OUTER_ITERS == 1 && cycles >= 15102027) ||
            (OUTER_ITERS == 40 && cycles >= 560631327)) begin
            $display("FAIL: Stage-4A did not reduce cycles; observed=%0d", cycles);
            $fatal(1);
        end
        $display("PASS: Stage-4A accelerated TV division; compute cycles=%0d", cycles);

        $display(
            "PASS: output pixels 4096/4096 exact; errors=0"
        );

        $display(
            "PASS: range_error=0, protocol_error=0"
        );

        $display(
            "PASS: outer iterations=%0d, compute cycles=%0d",
            OUTER_ITERS,
            cycles
        );

        $display(
            "PASS: final output range=[%0d,%0d], sum=%0d",
            min_out,
            max_out,
            sum_out
        );

        $display(
            "INFO: final simulation time=%0t",
            $time
        );

        // Mark complete ONLY after every check has passed.

        test_completed = 1'b1;

        $display(
            "ALL TESTS PASSED: Stage-3 TV-FISTA top-level integration"
        );

        $finish;

    end

endmodule


// ============================================================
// Simulation wrappers
// ============================================================

// Single iteration test.

module tb_fista_top_q11_one_iter;

    tb_fista_top_q11_run #(
        .OUTER_ITERS(1)
    ) u_run();

endmodule


// Complete 40-iteration test.

module tb_fista_top_q11_full;

    tb_fista_top_q11_run #(
        .OUTER_ITERS(40)
    ) u_run();

endmodule
