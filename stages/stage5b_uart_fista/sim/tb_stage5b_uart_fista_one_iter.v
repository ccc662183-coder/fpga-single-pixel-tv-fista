`timescale 1ns / 1ps
// Stage-5B full UART wire-level bridge test, reduced to OUTER_ITERS=1.
// Physically sends 17 chunk packets holding 1024 measurements; reconstructs
// 4096 output pixels through 32 full 256B replies; checks CRC and all pixels.
// Actual FPGA top default OUTER_ITERS=40. This TB does not change frozen RTL.
module tb_stage5b_uart_fista_one_iter;
    reg clk=0; always #10 clk=~clk;
    reg rst_n=0;
    reg uart_rx_i=1;
    wire uart_tx_o;
    stage5b_uart_fista_top #(.OUTER_ITERS(1),.TV_INNER_STEPS(35)) dut (
        .clk_50m(clk),.rst_n(rst_n),.uart_rx_i(uart_rx_i),.uart_tx_o(uart_tx_o));
    localparam integer BIT_NS=1000;
    reg [31:0] measurements [0:1023];
    reg [15:0] golden [0:4095];
    reg [7:0] payload [0:255];
    reg [7:0] received_bytes [0:16383];
    reg [7:0] last_payload [0:255];
    integer received_count=0, consumed=0;
    integer bit_idx, k, i, b, chunk, word_id, nwords, len, iter;
    integer timeout_clocks;
    integer pos, global_addr, checked;
    integer monitor_bit_ns;
    reg [7:0] monitor_byte;
    reg [15:0] calculated_crc, response_crc;
    integer errors=0;
    reg [15:0] request_seq=0;

    initial begin
      $readmemh("cat64_measurements_q11_s32.mem", measurements);
      $readmemh("cat64_expected_iter1_q11_s16.mem",golden);
    end
    initial begin
      #650_000_000; $fatal(1,"[FAIL] Stage-5B TB global timeout");
    end
    always @(negedge uart_tx_o) begin
       if (rst_n) begin
         monitor_bit_ns = BIT_NS;
         #(monitor_bit_ns/2);
         if (uart_tx_o !== 0) $fatal(1,"[FAIL] FPGA TX invalid START");
         for (bit_idx=0;bit_idx<8;bit_idx=bit_idx+1) begin
           #(monitor_bit_ns);
           monitor_byte[bit_idx]=uart_tx_o;
         end
         #(monitor_bit_ns);
         if (uart_tx_o !== 1) $fatal(1,"[FAIL] FPGA TX invalid STOP");
         if (received_count>=16384) $fatal(1,"[FAIL] monitor buffer overflow");
         received_bytes[received_count]=monitor_byte;
         received_count=received_count+1;
       end
    end

    function [15:0] crc_next;
      input [15:0] old_crc;
      input [7:0] v;
      reg [15:0] t;
      integer j;
      begin
        t=old_crc;
        for(j=7;j>=0;j=j-1)
          if (t[15] ^ v[j]) t={t[14:0],1'b0} ^ 16'h1021;
          else t={t[14:0],1'b0};
        crc_next=t;
      end
    endfunction

    task send_byte;
      input [7:0] v;
      integer j;
      begin
        @(negedge clk);
        uart_rx_i=0; #(BIT_NS);
        for(j=0;j<8;j=j+1) begin uart_rx_i=v[j]; #(BIT_NS); end
        uart_rx_i=1; #(BIT_NS);
      end
    endtask

    task send_packet;
      input [7:0] typ;
      input [15:0] seq;
      input integer count;
      integer j;
      reg [15:0] crc;
      begin
        crc=16'hFFFF;
        send_byte(8'hA5); send_byte(8'h5A);
        send_byte(8'h01); crc=crc_next(crc,8'h01);
        send_byte(typ); crc=crc_next(crc,typ);
        send_byte(seq[7:0]); crc=crc_next(crc,seq[7:0]);
        send_byte(seq[15:8]); crc=crc_next(crc,seq[15:8]);
        send_byte(count & 8'hFF); crc=crc_next(crc,count & 8'hFF);
        send_byte((count>>8) & 8'hFF); crc=crc_next(crc,(count>>8) & 8'hFF);
        for(j=0;j<count;j=j+1) begin
          send_byte(payload[j]); crc=crc_next(crc,payload[j]);
        end
        send_byte(crc[7:0]); send_byte(crc[15:8]);
      end
    endtask

    task read_reply;
      input [7:0] wanted_type;
      input [15:0] wanted_seq;
      input integer wanted_len;
      integer spin, offset, j;
      reg [15:0] crc;
      begin
        spin=0;
        while((received_count-consumed < wanted_len+10) && spin < 600000) begin
          @(negedge clk); spin=spin+1;
        end
        if(received_count-consumed < wanted_len+10)
          $fatal(1,"[FAIL] UART response timeout type=%02x seq=%04x",wanted_type,wanted_seq);
        offset=consumed;
        if (received_bytes[offset]!==8'hA5 || received_bytes[offset+1]!==8'h5A ||
            received_bytes[offset+2]!==8'h01 || received_bytes[offset+3]!==wanted_type ||
            received_bytes[offset+4]!==wanted_seq[7:0] || received_bytes[offset+5]!==wanted_seq[15:8] ||
            received_bytes[offset+6]!==(wanted_len & 8'hFF) ||
            received_bytes[offset+7]!==((wanted_len>>8)&8'hFF))
          $fatal(1,"[FAIL] response hdr type/seq/len mismatch type=%02x",wanted_type);
        crc=16'hFFFF;
        for(j=2;j<8+wanted_len;j=j+1) crc=crc_next(crc,received_bytes[offset+j]);
        response_crc={received_bytes[offset+9+wanted_len],received_bytes[offset+8+wanted_len]};
        if(crc!==response_crc) $fatal(1,"[FAIL] UART CRC mismatch expect=%04x got=%04x",crc,response_crc);
        for(j=0;j<wanted_len;j=j+1) last_payload[j]=received_bytes[offset+8+j];
        consumed=consumed+wanted_len+10;
        repeat(5) @(negedge clk);
      end
    endtask

    task query_status;
      input [15:0] seq;
      begin
        send_packet(8'h44,seq,0);
        read_reply(8'h45,seq,12);
      end
    endtask

    initial begin
      $display("===== STAGE-5B UART + ONE FISTA ITERATION TEST =====");
      repeat(8) @(negedge clk);
      rst_n=1;
      repeat(30) @(negedge clk);
      // Backward compatible baud status.
      send_packet(8'h10,16'h1001,0);
      read_reply(8'h11,16'h1001,4);
      if({last_payload[3],last_payload[2],last_payload[1],last_payload[0]}!==32'd1000000)
        $fatal(1,"[FAIL] backward-compatible baud status");
      $display("PASS: Stage-5B backward-compatible UART GET_STATUS");
      // Soft reset must preserve UART connectivity.
      send_packet(8'h48,16'h1002,0);
      read_reply(8'h49,16'h1002,1);
      if(last_payload[0]!==0) $fatal(1,"[FAIL] compute reset ack");
      $display("PASS: Stage-5B independent compute reset");
      // Send out-of-order packet first; must be rejected without writing any measurement.
      for(i=0;i<253;i=i+1) payload[i]=0;
      payload[0]=1;
      send_packet(8'h40,16'h1003,253);
      read_reply(8'h7F,16'h1003,2);
      if(last_payload[0]!==8'h40 || last_payload[1]!==8'd2 || dut.loaded_count!==0)
        $fatal(1,"[FAIL] out-of-order measurement packet was not rejected");
      $display("PASS: Stage-5B out-of-order LOAD rejected");
      // 16 x 63 + 1 x 16 = 1024 measurements, 32-bit little endian.
      for(chunk=0;chunk<17;chunk=chunk+1) begin
        nwords=(chunk==16)?16:63;
        len=1+nwords*4;
        payload[0]=chunk;
        for(i=0;i<nwords;i=i+1) begin
          word_id=chunk*63+i;
          payload[1+4*i]   = measurements[word_id][7:0];
          payload[1+4*i+1] = measurements[word_id][15:8];
          payload[1+4*i+2] = measurements[word_id][23:16];
          payload[1+4*i+3] = measurements[word_id][31:24];
        end
        send_packet(8'h40,16'h2000+chunk,len);
        read_reply(8'h41,16'h2000+chunk,4);
        global_addr=(chunk+1)*63;
        if(global_addr>1024) global_addr=1024;
        if(last_payload[0]!==chunk ||
           {last_payload[2],last_payload[1]}!==global_addr || last_payload[3]!==0)
           $fatal(1,"[FAIL] load ack chunk=%0d",chunk);
      end
      if(dut.loaded_count!==11'd1024 || dut.next_chunk!==5'd17)
        $fatal(1,"[FAIL] 1024 measurements not loaded");
      $display("PASS: Stage-5B UART 17 frames -> 1024x32-bit measurements, CRC/order exact");
      query_status(16'h3010);
      if(!last_payload[0][0] || {last_payload[3],last_payload[2]}!==1024)
        $fatal(1,"[FAIL] status READY and count=1024");
      // START single FISTA iteration via the same command as the 40-round board.
      send_packet(8'h42,16'h3011,0);
      read_reply(8'h43,16'h3011,1);
      if(last_payload[0]!==0) $fatal(1,"[FAIL] start ack");
      query_status(16'h3012);
      if(!last_payload[0][1]) $fatal(1,"[FAIL] STATUS did not show BUSY");
      $display("PASS: Stage-5B START and busy state visible over real UART frames");
      wait(dut.completed == 1'b1);
      query_status(16'h3013);
      if(!last_payload[0][2] || {last_payload[3],last_payload[2]}!==1024)
        $fatal(1,"[FAIL] STATUS DONE not returned");
      $display("PASS: Stage-5B compute finished; iteration counter=%0d",last_payload[1]);
      checked=0;
      // Every 64x64 output pixel is read through serial UART and checked.
      for(chunk=0;chunk<32;chunk=chunk+1) begin
        payload[0]=chunk;
        send_packet(8'h46,16'h4000+chunk,1);
        read_reply(8'h47,16'h4000+chunk,256);
        for(i=0;i<128;i=i+1) begin
          word_id=chunk*128+i;
          if({last_payload[2*i+1],last_payload[2*i]}!==golden[word_id]) begin
             if(errors<4) $display("[FAIL] pixel=%0d want=%04x got=%04x",word_id,
                      golden[word_id],{last_payload[2*i+1],last_payload[2*i]});
             errors=errors+1;
          end
          checked=checked+1;
        end
      end
      if(errors !=0 || checked!=4096) $fatal(1,"[FAIL] reconstructed pixels errors=%0d",errors);
      $display("PASS: Stage-5B 4096/4096 one-iteration golden pixels through 32 UART result frames");
      // Soft reset allows another image without resetting UART transceiver.
      send_packet(8'h48,16'h5000,0);
      read_reply(8'h49,16'h5000,1);
      query_status(16'h5001);
      if({last_payload[3],last_payload[2]}!==0 || last_payload[0][2]!==0)
        $fatal(1,"[FAIL] soft reset did not clear loaded count / completed flag");
      $display("PASS: Stage-5B restart/reset leaves serial link active");
      $display("ALL TESTS PASSED: Stage-5B UART -> TV-FISTA -> UART single iteration");
      $finish;
    end
endmodule
