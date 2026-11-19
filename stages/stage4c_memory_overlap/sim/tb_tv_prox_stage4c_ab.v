`timescale 1ns/1ps
// Stage-4C independent TV-Prox A/B regression (35 Jacobi iterations).
// Reference is the exact Stage-4B RTL renamed at the module declaration;
// optimized DUT differs only in memory scheduler / combinational timing.
// Both consume the SAME f vector and use the SAME Stage-4B projection RTL.
module tb_tv_prox_stage4c_ab;
    reg clk=1'b0;
    always #10 clk=~clk; // 50 MHz
    reg rst_n=1'b0;
    reg load_we=1'b0;
    reg [11:0] load_addr=12'd0;
    reg signed [15:0] load_data=16'sd0;
    reg start=1'b0;
    reg read_en=1'b0;
    reg [11:0] read_addr=12'd0;
    wire ready_ref, ready_opt;
    wire busy_ref, busy_opt;
    wire done_ref, done_opt;
    wire read_valid_ref,read_valid_opt;
    wire [15:0] read_data_ref,read_data_opt;
    reg [15:0] input_vec [0:4095];
    reg [15:0] expected_vec [0:4095];
    reg started=1'b0;
    reg seen_ref=1'b0,seen_opt=1'b0;
    integer clock_counter=0;
    integer cycles_ref=0,cycles_opt=0;
    integer i,errors=0,sum_ref=0,sum_opt=0;
    integer min_opt=32767,max_opt=-32768;

    tv_prox64_bram_q11_reference #(.INNER_STEPS(35)) ref_dut (
       .clk(clk),.rst_n(rst_n),.load_we(load_we),.load_addr(load_addr),
       .load_data(load_data),.start(start),.ready(ready_ref),
       .busy(busy_ref),.done(done_ref),.read_en(read_en),
       .read_addr(read_addr),.read_valid(read_valid_ref),
       .read_data(read_data_ref)
    );
    tv_prox64_bram_q11 #(.INNER_STEPS(35)) opt_dut (
       .clk(clk),.rst_n(rst_n),.load_we(load_we),.load_addr(load_addr),
       .load_data(load_data),.start(start),.ready(ready_opt),
       .busy(busy_opt),.done(done_opt),.read_en(read_en),
       .read_addr(read_addr),.read_valid(read_valid_opt),
       .read_data(read_data_opt)
    );

    always @(posedge clk) begin
        if (!rst_n) begin
            clock_counter <= 0;
            seen_ref <= 1'b0;
            seen_opt <= 1'b0;
            cycles_ref <= 0;
            cycles_opt <= 0;
        end else if (started) begin
            clock_counter <= clock_counter+1;
            if (done_ref && !seen_ref) begin
                seen_ref <= 1'b1;
                cycles_ref <= clock_counter;
            end
            if (done_opt && !seen_opt) begin
                seen_opt <= 1'b1;
                cycles_opt <= clock_counter;
            end
        end
    end
    initial begin
        #1000000000;
        $display("FAIL: Stage-4C TV Prox A/B global timeout");
        $fatal(1);
    end
    initial begin
        $readmemh("input_f_q11.mem",input_vec);
        $readmemh("expected_prox_q11.mem",expected_vec);
        repeat(8) @(negedge clk);
        rst_n=1'b1;
        for(i=0;i<4096;i=i+1) begin
            @(negedge clk);
            load_we=1'b1;
            load_addr=i[11:0];
            load_data=$signed(input_vec[i]);
        end
        @(negedge clk);
        load_we=1'b0;
        if (ready_ref !== 1'b1 || ready_opt !== 1'b1) begin
            $display("FAIL: TV cores are not both ready after loading");
            $fatal(1);
        end
        start=1'b1;
        started=1'b1;
        @(negedge clk);
        start=1'b0;
        wait(seen_ref && seen_opt);
        @(negedge clk);
        $display("INFO: A/B TV Prox cycles baseline=%0d optimized=%0d saved=%0d",
                 cycles_ref,cycles_opt,cycles_ref-cycles_opt);
        if(cycles_opt >= cycles_ref) begin
            $display("FAIL: Stage-4C TV Prox did not reduce cycles");
            $fatal(1);
        end
        if (cycles_ref-cycles_opt != 442332) begin
            $display("FAIL: unexpected cycle saving (expected 442332, got %0d)",
                     cycles_ref-cycles_opt);
            $fatal(1);
        end
        for(i=0;i<4096;i=i+1) begin
            @(negedge clk);
            read_en=1'b1;
            read_addr=i[11:0];
            @(posedge clk);
            #1;
            if(read_valid_ref !== 1'b1 || read_valid_opt !== 1'b1 ||
               read_data_ref !== read_data_opt ||
               read_data_ref !== expected_vec[i]) begin
                errors=errors+1;
                if(errors <= 10)
                    $display("ERROR pixel %0d ref=%0d opt=%0d golden=%0d validR=%b validO=%b",
                             i,$signed(read_data_ref),$signed(read_data_opt),
                             $signed(expected_vec[i]),read_valid_ref,read_valid_opt);
            end
            sum_ref=sum_ref+$signed(read_data_ref);
            sum_opt=sum_opt+$signed(read_data_opt);
            if($signed(read_data_opt) < min_opt) min_opt=$signed(read_data_opt);
            if($signed(read_data_opt) > max_opt) max_opt=$signed(read_data_opt);
        end
        @(negedge clk);
        read_en=1'b0;
        if(errors!=0 || sum_ref!=3926432 || sum_opt!=3926432 ||
           min_opt!=107 || max_opt!=1530) begin
            $display("FAIL: TV Prox A/B errors=%0d sums=%0d,%0d range=[%0d,%0d]",
                    errors,sum_ref,sum_opt,min_opt,max_opt);
            $fatal(1);
        end
        $display("PASS: Stage-4C vs frozen Stage-4B TV Prox 4096/4096 bit-exact");
        $display("PASS: Stage-1 independent golden 4096/4096 bit-exact");
        $display("PASS: A/B cycles baseline=%0d optimized=%0d saved=%0d",
                 cycles_ref,cycles_opt,cycles_ref-cycles_opt);
        $display("PASS: TV Prox summary range=[%0d,%0d] sum=%0d",
                 min_opt,max_opt,sum_opt);
        $display("ALL TESTS PASSED: Stage-4C BRAM prefetch and state-overlap A/B");
        $finish;
    end
endmodule
