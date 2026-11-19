`timescale 1ns/1ps
module tb_tv_prox64_bram_q11;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst_n = 1'b0;
    reg load_we = 1'b0;
    reg [11:0] load_addr = 12'd0;
    reg signed [15:0] load_data = 16'sd0;
    reg start = 1'b0;

    wire ready, busy, done;

    reg read_en = 1'b0;
    reg [11:0] read_addr = 12'd0;
    wire read_valid;
    wire [15:0] read_data;

    reg [15:0] input_vec [0:4095];
    reg [15:0] expected_vec [0:4095];

    integer i;
    integer cycles;
    integer errors;
    integer sum_got;
    integer min_got;
    integer max_got;

    tv_prox64_bram_q11 #(.INNER_STEPS(35)) dut (
        .clk(clk),
        .rst_n(rst_n),
        .load_we(load_we),
        .load_addr(load_addr),
        .load_data(load_data),
        .start(start),
        .ready(ready),
        .busy(busy),
        .done(done),
        .read_en(read_en),
        .read_addr(read_addr),
        .read_valid(read_valid),
        .read_data(read_data)
    );

    initial begin
        #500000000;
        $display("FAIL: global simulation timeout");
        $fatal(1);
    end

    initial begin
        $readmemh("input_f_q11.mem", input_vec);
        $readmemh("expected_prox_q11.mem", expected_vec);

        repeat (6) @(negedge clk);
        rst_n = 1'b1;

        // Load the complete 64x64 input image.
        for (i = 0; i < 4096; i = i + 1) begin
            @(negedge clk);
            load_we   = 1'b1;
            load_addr = i[11:0];
            load_data = $signed(input_vec[i]);
        end
        @(negedge clk);
        load_we = 1'b0;

        if (ready !== 1'b1) begin
            $display("FAIL: engine is not ready after image loading");
            $fatal(1);
        end

        // Start one full 35-iteration TV Prox operation.
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        cycles = 0;
        while (done !== 1'b1) begin
            @(negedge clk);
            cycles = cycles + 1;
            if (cycles > 25000000) begin
                $display("FAIL: TV Prox exceeded 25,000,000 clocks");
                $fatal(1);
            end
        end

        if (busy !== 1'b0 || ready !== 1'b1) begin
            $display("FAIL: ready/busy status after completion");
            $fatal(1);
        end

        // Read and compare all 4096 output pixels.
        errors = 0;
        sum_got = 0;
        min_got = 2147483647;
        max_got = -2147483647;

        for (i = 0; i < 4096; i = i + 1) begin
            @(negedge clk);
            read_en = 1'b1;
            read_addr = i[11:0];

            @(posedge clk);
            #1;
            if (read_valid !== 1'b1) begin
                $display("FAIL: read_valid missing at address %0d", i);
                $fatal(1);
            end

            sum_got = sum_got + $signed(read_data);
            if ($signed(read_data) < min_got) min_got = $signed(read_data);
            if ($signed(read_data) > max_got) max_got = $signed(read_data);

            if (read_data !== expected_vec[i]) begin
                errors = errors + 1;
                if (errors <= 12)
                    $display("MISMATCH addr=%0d got=%0d expected=%0d",
                             i, $signed(read_data), $signed(expected_vec[i]));
            end
        end

        @(negedge clk);
        read_en = 1'b0;

        if (errors != 0) begin
            $display("FAIL: %0d / 4096 output pixels mismatch", errors);
            $fatal(1);
        end

        if (sum_got != 3926432 || min_got != 107 || max_got != 1530) begin
            $display("FAIL: output checksum/range mismatch: sum=%0d min=%0d max=%0d",
                     sum_got, min_got, max_got);
            $fatal(1);
        end

        $display("PASS: 64x64 BRAM TV Prox, all 4096 pixels match");
        $display("PASS: 35 Jacobi dual iterations, Q5.11 arithmetic");
        $display("PASS: output range=[%0d,%0d], sum=%0d", min_got, max_got, sum_got);
        $display("PASS: compute cycles=%0d", cycles);
        $display("ALL TESTS PASSED: Stage-1 64x64 BRAM TV Prox");
        $finish;
    end
endmodule
