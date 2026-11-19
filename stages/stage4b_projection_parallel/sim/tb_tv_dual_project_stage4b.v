`timescale 1ns/1ps
// Stage-4B independent A/B projection regression:
// exact output agreement for original slow/fast paths and edge cases.
module tb_tv_dual_project_stage4b;
    reg clk = 1'b0;
    always #10 clk = ~clk; // 50 MHz
    reg rst_n = 1'b0;
    reg start = 1'b0;
    reg signed [15:0] vx = 0, vy = 0;
    wire ref_ready, ref_valid, opt_ready, opt_valid;
    wire signed [15:0] ref_x, ref_y, opt_x, opt_y;
    integer k, errors, slow_count, fast_count;
    integer ref_ticks_sum, opt_ticks_sum;
    integer ref_ticks, opt_ticks;
    integer seed;
    integer clock_count;
    integer watchdog;
    reg ref_seen, opt_seen;
    reg signed [15:0] ref_x_saved, ref_y_saved, opt_x_saved, opt_y_saved;
    reg signed [15:0] a, b;
    reg [31:0] squared;

    tv_dual_project_q11_reference u_reference (
        .clk(clk), .rst_n(rst_n), .start(start),
        .vx_in(vx), .vy_in(vy), .ready(ref_ready),
        .valid_out(ref_valid), .px_out(ref_x), .py_out(ref_y)
    );
    tv_dual_project_q11 u_optimized (
        .clk(clk), .rst_n(rst_n), .start(start),
        .vx_in(vx), .vy_in(vy), .ready(opt_ready),
        .valid_out(opt_valid), .px_out(opt_x), .py_out(opt_y)
    );

    task run_case;
        input signed [15:0] x_in;
        input signed [15:0] y_in;
        begin
            // Wait until both implementations become idle.
            @(negedge clk);
            while (ref_ready !== 1'b1 || opt_ready !== 1'b1)
                @(negedge clk);
            vx = x_in; vy = y_in; start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            ref_seen = 1'b0; opt_seen = 1'b0;
            ref_ticks = 0; opt_ticks = 0;
            watchdog = 0;
            while (!(ref_seen && opt_seen) && watchdog < 150) begin
                @(negedge clk);
                watchdog = watchdog + 1;
                if (!ref_seen) begin
                    ref_ticks = ref_ticks + 1;
                    if (ref_valid === 1'b1) begin
                        ref_seen = 1'b1;
                        ref_x_saved = ref_x;
                        ref_y_saved = ref_y;
                    end
                end
                if (!opt_seen) begin
                    opt_ticks = opt_ticks + 1;
                    if (opt_valid === 1'b1) begin
                        opt_seen = 1'b1;
                        opt_x_saved = opt_x;
                        opt_y_saved = opt_y;
                    end
                end
            end
            if (!(ref_seen && opt_seen)) begin
                $display("FAIL timeout case %0d input=(%0d,%0d)", k,x_in,y_in);
                $fatal(1);
            end
            if (ref_x_saved !== opt_x_saved || ref_y_saved !== opt_y_saved) begin
                $display("FAIL case=%0d input=(%0d,%0d) ref=(%0d,%0d) opt=(%0d,%0d)",
                          k,x_in,y_in,ref_x_saved,ref_y_saved,opt_x_saved,opt_y_saved);
                $fatal(1);
            end
            // Compute magnitude with signed multipliers as in the source RTL.
            squared = u_reference.sumsquared;
            if (squared > 32'd4194304) begin
                slow_count = slow_count + 1;
                if (opt_ticks >= ref_ticks) begin
                    $display("FAIL no speed gain case=%0d ref=%0d opt=%0d",k,ref_ticks,opt_ticks);
                    $fatal(1);
                end
            end else begin
                fast_count = fast_count + 1;
                if (opt_ticks != ref_ticks) begin
                    $display("FAIL fast path timing changed case=%0d",k);
                    $fatal(1);
                end
            end
            ref_ticks_sum = ref_ticks_sum + ref_ticks;
            opt_ticks_sum = opt_ticks_sum + opt_ticks;
        end
    endtask

    initial begin
        errors = 0; slow_count = 0; fast_count = 0;
        ref_ticks_sum = 0; opt_ticks_sum = 0;
        seed = 32'h43A8D112;
        #100;
        @(negedge clk);
        rst_n = 1'b1;
        // First 256 pairs systematically hit signs and magnitudes around
        // 0, +/-2048, +/-32768, where saturation/fast path can change.
        for (k=0; k<2048; k=k+1) begin
            case (k % 8)
                0: begin a=16'sd0; b=16'sd0; end
                1: begin a=16'sd2048; b=16'sd0; end
                2: begin a=16'sd2049; b=16'sd0; end
                3: begin a=-16'sd2049; b=16'sd1; end
                4: begin a=16'sd32767; b=-16'sd32768; end
                5: begin a=-16'sd32768; b=16'sd32767; end
                6: begin a=$random(seed); b=$random(seed); end
                7: begin a=$random(seed) >>> 3; b=$random(seed) >>> 3; end
            endcase
            run_case(a,b);
        end
        if (slow_count==0 || fast_count==0) $fatal(1,"FAIL bad coverage");
        $display("PASS: Stage-4B projection A/B exact 2048/2048 cases, errors=0");
        $display("PASS: fast=%0d slow=%0d, both paths covered",fast_count,slow_count);
        $display("PASS: A/B total projected cycles reference=%0d optimized=%0d saved=%0d",
                 ref_ticks_sum,opt_ticks_sum,ref_ticks_sum-opt_ticks_sum);
        $display("ALL TESTS PASSED: Stage-4B projection radix-8 parallel divider");
        $finish;
    end
    initial begin
        #20000000;
        $fatal(1,"FAIL: Stage-4B regression timeout");
    end
endmodule
